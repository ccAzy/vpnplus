# vpnplus 重构设计 — 稳定优先的保守拆分

> 目标：在不加固定隧道等额外资产、不加版本号的前提下，把 5 个单体 bash 拆成可低成本变更的系统，满足 a稳定 > c改动成本 > b高效，且保持 `bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_singbox.sh) | bash` 100% 兼容。

## 1. 现状与约束

* 单体：`bootstrap(5k)` `deploy_optimize(26k)` `deploy_singbox(51k)` `verify(13k)` `cleanup(14k)`，`deploy_singbox` 承载 9 职责，`sb.sh` 外部菜单 `5001e76` 强耦合
* 已知坑（rn1 实测）：`chrony` 未装导致 `bad timestamp` 全不通、`40254` 端口污染、`KEEP_PORT` 漂移、`PREROUTING` 残留、`sb_feed` 卡死、`Argo` 翻滚
* 约束：bash 保持、入口不动、无额外付费资产、无版本号

## 2. 架构

薄入口 + `lib/` 单职责。

```
vpnplus/
├── bootstrap.sh            # 10行：source lib/common.sh; source lib/time.sh; 校验+调common
├── deploy_optimize.sh      # ~200行 编排：check_env -> install_deps -> ensure_time_sync -> bbr -> sysctl
├── deploy_singbox.sh       # ~250行 编排：ensure_time_sync -> sb -> subscription -> hopping -> argo -> firewall -> warp
├── verify.sh               # ~300行 编排：依次 source lib/verify/*.sh
├── cleanup.sh              # 调用 lib/firewall.sh:clean_chains
└── lib/
    ├── common.sh           # log/manifest/run/trap/BASE_PACKAGES
    ├── time.sh             # ensure_time_sync() / check_time_sync()
    ├── firewall.sh         # persist_firewall, clean_chains, apply_antiprobe, config_port_hopping
    ├── singbox.sh          # install_singbox_yg, sb_feed, assert_sb_menu
    ├── subscription.sh     # setup_subscription (KEEP_PORT + RESET_SUB)
    ├── argo.sh             # start_argo, install_argo_keepalive v3
    ├── warp.sh             # setup_warp, setup_domain_routing
    └── verify/
        ├── time.sh
        ├── tuic.sh         # 40254污染/DNAT/回环204
        ├── port.sh
        └── subscription.sh
```

`lib/common.sh` 统一 `RED/GREEN/YELLOW/CYAN`、`info/ok/warn/fail`、`manifest()`、`run()` 对 `DRY_RUN` 的包装，避免各脚本各写一套。

## 3. 组件职责

* **common.sh**：日志、颜色、manifest、trap、BASE_PACKAGES 列表（含 chrony）
* **time.sh**：`ensure_time_sync()` 写 `/etc/chrony/chrony.conf`（国内源 + makestep 1 3 + rtcsync）→ `enable --now` → `makestep` → 校验 `Leap Normal`；`check_time_sync()` 供 `verify.sh` 调用，含 `ntpdate -q` 偏移提示
* **firewall.sh**：独立链 `ACVPN_ANTIPROBE/ACVPN_PORTHOP` 的创建/清理/持久化（`persist_firewall` 双保险：netfilter-persistent + `vpnplus-netfilter-restore.service`），清理 PREROUTING 残留跳跃段
* **singbox.sh**：`sb.sh` 的固定 commit + SHA256 强制校验、重跑哈希复审、`sb_feed` 的 PID 差集精确清理 + 去色落盘
* **subscription.sh**：`KEEP_PORT` 复用 + `RESET_SUB=1/--reset-sub` 强制轮转（删 `subport.log/subtoken.log/websbox/*` 再重建）
* **argo.sh**：`--protocol auto` 补丁、`keepalive v3`（flock + 双检 + 翻滚冷却 5次/30min → 1h）
* **warp.sh**：`sbwpph` 安装 + 域名分流（`openai...` 列表）+ `fix_mport_dup` 去重
* **verify/**：每项一个文件，可单独 `bats` 测；`tuic.sh` 含污染检查与 `127.0.0.1:$TU_PORT → 204` 回环探活

## 4. 数据流

```
bootstrap.sh -> check_env -> install_deps(BASE_PACKAGES+chrony) -> ensure_time_sync -> gai.conf
deploy_optimize.sh -> check_env -> install_deps -> ensure_time_sync -> install_bbrv3 -> sysctl/ethtool/qdisc/limits/rss -> grub -> MARK
deploy_singbox.sh -> check_env -> ensure_time_sync -> install_singbox_yg -> setup_subscription(KEEP_PORT/RESET_SUB) -> port_hopping -> argo -> firewall -> warp -> verify(轻量)
verify.sh -> common -> time.sh -> port.sh -> tuic.sh -> subscription.sh -> argo.sh
cleanup.sh -> bak_firewall -> clean_chains(lib) -> stop_services -> kill_procs -> crontab -> units -> files
```

所有写文件操作先 `cp file file.bak.$(date +%s)` 再原子 `cat > file.tmp && mv file.tmp file`，`trap` 保证半成品可回滚。

## 5. 错误处理与幂等

* `set -euo pipefail` 全局，`run()` 包装对 `DRY_RUN` 的短路；可选步骤 `|| warn` 继续，核心步骤 `|| DEPLOY_OK=false` 不写 MARK
* `sb_feed` 超时 + PID 差集 + 去色日志落 `/var/log/vpnplus-sbfeed.log`
* `KEEP_PORT` 合法性校验 1024-65535，`RESET_SUB` 前置清理，`config_port_hopping` 先清 PREROUTING 残留再建链
* `persist_firewall` 与 `setup_logrotate` 均幂等，多次跑不叠加
* 失败 trap 统一指引：`cleanup --dry-run` 预览 / 重跑 / 彻底重建

## 6. 测试与可观测

* `bash -n` + `shellcheck -S warning` 门禁（已过，仅 `patched_ok` 一个可忽略 warning）
* `bats` 单测：`lib/time.sh`（chrony Normal）、`lib/firewall.sh`（链存在/DNAT指向）、`lib/verify/tuic.sh`（污染/回环）
* `verify.sh` 从自检升级为端到端：`ss -tlnp` + `iptables -L` + `127.0.0.1 TUIC 204` + `curl 订阅 200`，区分本机坏 vs 外网墙
* 日志：`/var/log/vpnplus-*.log` + `manifest` + `sbfeed.log`，`logrotate` 周轮 4 份

## 7. 交付与兼容

* 对外入口零变更，`bootstrap.sh`/`deploy_optimize.sh`/`deploy_singbox.sh` 参数新增 `--reset-sub` 与 `RESET_SUB` 环境变量，向后兼容
* 无版本号，不写 `VERSION` 文件
*  rollout：先 `rn1` 已验证 `54321`，其余 6 台批量 `deploy_optimize.sh` 补 chrony 即可
