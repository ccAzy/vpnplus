# Changelog

## 2026-08-27 — 时钟与 TUIC 单点故障修复（rn1 实测）

* **P0 时钟漂移（`bad timestamp` 全不通）**：`deploy_optimize.sh`/`deploy_singbox.sh` 的 `install_dependencies` 新增 `chrony`，新增 `ensure_time_sync()`（国内源 `ntp.aliyun/ntp1.aliyun/cn.pool/pool.ntp` + `makestep 1 3` + `rtcsync`，`systemctl enable --now chrony` 并 `chronyc makestep` 即时拨正），`verify.sh` 新增 `chrony Leap Normal` / `System clock synchronized` / `ntpdate -q` 偏移检查。rn1 实测 `System clock synchronized: no` / `chronyc: command not found`，修复后 `Stratum 2 Normal`。
* **P0 TUIC 单点端口污染**：rn1 `40254` 直连在外网被精准限速（本机回环 204 通、外网 Hy2 通、TUIC 40254 超时8s、TUIC 44000跳跃/54321 新端口秒通 204），`verify.sh` 新增 `TUIC 端口污染` 与 `端口跳跃 DNAT 指向` 检查 + 本地回环 `127.0.0.1:$TU_PORT → google 204` 自检，区分“本机坏”与“外网墙”。rn1 已切 `40254→54321` 并 `iptables -t nat DNAT 43000:45000→54321` + `ACVPN_ANTIPROBE 54321`，`clmi.yaml/tuic5.txt/jhsub` 同步 54321，重跑 `netfilter-persistent save`。
* **P0 订阅轮转（暴露后一键换链）**：`deploy_singbox.sh` 新增 `RESET_SUB=1` / `--reset-sub`（`KEEP_PORT` 逻辑前置清理 `subport.log/subtoken.log/websbox/*`），默认仍复用旧订阅保持客户端有效，暴露后 `RESET_SUB=1 bash deploy_singbox.sh` 即生成全新 token/端口，旧链接立即 404。
* **影响面**：其余 6 台（hk/jp/cc/vn/rn2/qq）已验证同依赖缺口，建议批量重跑 `deploy_optimize.sh` 补 chrony。

## 2026-08-25 — 全面审计修复（11 项，含 1 真实 Bug）

针对公开仓库做全面审计（5 脚本 + 文档），修正全部发现项：

- **`deploy_singbox.sh` iptables 持久化修复（高优）**：旧实现第三层 `iptables-save` 只写文件、无开机加载，重启后 `ACVPN_PORTHOP`/`ACVPN_ANTIPROBE` 独立链规则全部丢失。新增 `persist_firewall()`：优先 netfilter-persistent，并**额外写 `/etc/iptables/rules.v4|v6` + 自建 `vpnplus-netfilter-restore.service`（network-pre.target 前恢复）双保险**。两处调用点（端口跳跃/防探测）统一收敛。bootstrap/deploy 依赖新增 `iptables-persistent`。
- **`cleanup.sh` 漏删 Argo 保活脚本（真实 Bug）**：`rm_files` 只删旧名 `acvpn-argo-keepalive.sh`，**未删新版 `vpnplus-argo-keepalive.sh`**，清理后留孤儿。现已补删，并连带清理 `vpnplus-netfilter-restore.service`、iptables 快照、lock 文件、logrotate 配置；`verify_clean` 新增对应断言。
- **`deploy_singbox.sh` 保活脚本 v3**：`install_argo_keepalive` 改为**纯单引号 heredoc 直写**（彻底消除旧版 bash -c 双层转义出错风险），并升级逻辑：
  - **flock 互斥**：禁止两个保活实例并发 pkill/重启互踩
  - **进程识别统一**：临时隧道口径改为 `cloudflared+tunnel+--url`，与 `start_argo`/`cleanup` 一致（不再只认 localhost）
  - **cloudflared 路径自动探测**：不再硬编码 `/etc/s-box/cloudflared`
  - **WS 端口健壮化**：优先按 type==vless + transport==ws 取，退化 inbounds[1]
  - **翻动检测**：30 分钟内连续重连 ≥5 次 → 触发 1 小时冷却并写 `argo-flapping.marker`（防域名无限漂移折腾客户端）
- **`deploy_singbox.sh` sb.sh 哈希复查**：重跑时即使 sb 已存在也校验哈希（原版 或 Argo 补丁白名单 `SB_PATCH_MARKER`），不在可信集合则重新下载覆盖，避免"首次校验后 /usr/bin/sb 被篡改/被 sed 补丁失去 pin 意义"。补丁版哈希由 `apply_argo_patch` 实时记录。
- **`deploy_singbox.sh` sb_feed 精确清理 + 日志**：只杀"本次调用期间新出现"的 sb 进程（PID 差集），不再 `pkill -f 'bash /usr/bin/sb'` 误杀同机手动开的 sb 面板；sb 交互输出去色后追加到 `/var/log/vpnplus-sbfeed.log` 供失败回溯。
- **`deploy_singbox.sh` sb 菜单版本指纹**：首次部署前抓 sb 横幅识别版本，非预期 v2x 系列则告警（防菜单序号漂移导致安装"产物缺失才报错"难排查）。
- **`deploy_singbox.sh` 失败 trap**：中断时明确给出恢复指引（cleanup 预览/重跑/彻底重建 + sbfeed 日志位置），不再带着半配置无提示退出。
- **`deploy_singbox.sh` 可调常量收敛**：端口跳跃段（40000:42000/43000:45000）与限速/连接数阈值集中到顶部 `readonly` 常量，清除散落各处的魔法数，杜绝 2026-08-21 那类单点改漏。
- **`deploy_singbox.sh` 日志轮转**：新增 `setup_logrotate`（step 7），对 vpnplus 各类日志 + `argo.log` 周轮+保留 4 份+压缩（`copytruncate` 防 tee/重定向句柄丢失）。
- **`verify.sh` 增强**：新增校验 netfilter-restore unit 存在/启用、logrotate 配置、保活脚本 + cron + flock、网络调优服务 enable 状态。
- **`cleanup.sh` 进程口径统一**：`kill_procs`/`verify_clean` 改用 `cloudflared.*tunnel.*--url`，与保活脚本一致；`pgrep -fc` 改用 `pgrep -f | wc -l` 防自匹配误计。
- **审计方法论沉淀**：全面审计读完全部 5 脚本+CHANGELOG+SKILL，逐项标注优先级与诚实边界（需真机确认项以#3/#5 类锚点标出，余皆代码直接判定）。

## 2026-08-24 — 稳定性修复（所有改动已在 HK 服务器 85.121.51.211 实测验证）

- **`deploy_singbox.sh` Argo 临时隧道保活升级 v2（三级自愈）**：原保活只查进程是否存在，进程僵死（连接边缘断开）时不处理、重连后也不同步新域名。v2 改为：
  - **L1** 进程缺失 → 重启
  - **L2** 进程在但当前域名 HTTP 探测为 000（无任何状态码，二次确认防瞬时抖动）→ 判僵死 → 重启换新域名
  - **L3** 重连后域名变化 → 自动刷新订阅（jhsub/clmi/sbox 全部指向新域名），并兜底补同步不一致
  - HK 真机实测：杀进程→keepalive 自动重启（域名 cant-building→baptist-fourth-permit-geological）→ 订阅同步 → 客户端经新 Argo 域名端到端 HTTP 204。
- **`deploy_singbox.sh` VMESS_LOCK 默认 `on→off`**：默认不启用防主动探测防火墙锁端口，明文 VMess 公网直连。适合仅密钥登录+关闭密码登录+改 SSH 端口、无多余暴露面、希望节点全通的场景（HK 实测 2082 明文端口由"不通"变通）。需要额外防探测时设 `VMESS_LOCK=on`。
- **`deploy_singbox.sh` 新增 `sb_feed` 包装函数**：统一所有 sb(sing-box-yg) 菜单投喂（安装/订阅/WARP/域名分流/Argo），解决上游 sb 子菜单"完成操作后 `sleep 3 && sb` 递归拉起新面板、管道喂完存 stdin 耗尽导致脚本卡死/残留孤儿 sb 进程"的问题。末尾补多组 0 逐层退出 + timeout 限时 + 结束强杀残留，根治 `rm -f /etc/.vpnplus-singbox && bash deploy_singbox.sh` 强制重跑卡死。
- **`deploy_singbox.sh` 配置端口跳跃前清理 PREROUTING 过期跳跃段残留**：重跑会累积指向已废弃端口的孤立 UDP DNAT/REDIRECT（40000:42000/43000:45000/40000:41000），排在 `ACVPN_PORTHOP` 前把 hy2/tuic 跳跃段流量引入不存在的端口 → 握手无响应（Karing/V2rayN 实测不通）。现按行号幂等清除（真机验证），不碰 ACVPN_PORTHOP 链内规则及其他 NAT。
- **`deploy_singbox.sh` 订阅端口稳定性**：`setup_subscription` 重跑时探测并复用已有 `/etc/s-box/subport.log` 端口（1024-65535 合法段），不再每次随机 → 客户端订阅地址重跑后保持有效；无旧端口才随机。
- **`verify.sh` Argo 可达判定修正**：trycloudflare 隧道代理 WS 服务，根路径 404/4xx 是正常响应（能拿到状态码=边缘→隧道→本地链路通），仅 HTTP 000（连不上/超时）才算不可达，消除误报。
- **`verify.sh` 新增"PREROUTING 无残留端口跳跃段"检查**：部署后能发现过期跳跃段残留（提醒重跑 deploy 自动清理）。
- **`cleanup.sh` 兜底清理扩展匹配 REDIRECT 型残留**：除 DNAT 外，同时清理旧配置遗留的 REDIRECT 40000:41000 型重复跳跃规则。

## 2026-08-21 — 逻辑审查修复（三处）

- 修复 `deploy_singbox.sh` 端口跳跃启用条件：`&&`/`||` 同优先级左结合导致只装 Hysteria2（无 Tuic）时整条 `ACVPN_PORTHOP` 链被静默跳过；改为显式分组 `{ ...; } || { ...; }`，单协议/双协议/双缺失四象限实测验证。
- 修复 `deploy_optimize.sh` 两处 `set -e` 中断路径：`apply_ethtool`、`ensure_grub_boot` 存在 `return 1` 分支却被裸调用，一旦触发会中止整个脚本（跳过资源限制、多队列持久化、成功标记与重启）；改为 `|| warn` 降级继续。
- 修复 `verify.sh` 与文档不一致：README/SKILL 教的 `SERVER_IP=x.x.x.x bash verify.sh` 环境变量用法此前不生效（脚本只读 `$1`）；现在两种传参方式均支持。

## 2026-08-20 — 全项目流程与逻辑审查修复

- README/SKILL 改为“部署前置 + 第一/二/三步”，不再把环境准备写成“第零步”。
- 修复 `deploy_optimize.sh` 与 `deploy_singbox.sh` 的 dry-run：预览模式不再继续检查不存在的真实产物，也不执行系统写入/服务/防火墙/重启。
- 修复 `bootstrap.sh`：`git`、`xz-utils`、`tmux` 现在同时进入包状态检查和命令可用性检查，不再出现“列在清单但漏检”。
- 修复 `deploy_singbox.sh` 重写时遗漏的最终订阅链接输出（Clash/Mihomo、Sing-box、通用聚合）。
- 收紧 cleanup：不再全局杀 busybox；cron 只过滤 vpnplus/旧 ACVPN 自己的路径；未确认归属的 cloudflared systemd unit 和 nftables sing-box 表保留不动。
- cleanup 增加独立防火墙链清理结果验证。
- 增加 HTTP 高端口订阅链接的移动网络拦截提示。
- 增加已知限制：Private 仓库的匿名 raw 安装命令会返回 404；完整链路仍需真实 VPS 端到端验证。

## 2026-08-20 — 环境准备优化

- 新增 `bootstrap.sh`：统一检查/安装 Debian/Ubuntu 基础依赖，不装内核、不改防火墙、不重启。
- 两个部署脚本增加依赖兜底：即使跳过 bootstrap，也会明确安装缺失工具；apt 更新/安装失败直接中止，不再静默继续。
- 依赖清单覆盖 `curl`、`jq`、`git`、`xz-utils`、`tmux`、`iproute2`、`iptables`、`procps`、`psmisc`、`util-linux`、`cron`、`ethtool`、`kmod`、`ca-certificates`，兼顾 vpnplus 与 Hermes CLI 的基础环境。
- `git`/`xz-utils` 供 Hermes 安装器使用，`tmux` 用于 SSH 断开后保持 Agent 会话；`build-essential` 仍不默认安装。
- 修复 `deploy_optimize.sh` 在环境预检前就调用 apt 的顺序问题；非 Debian/Ubuntu 环境现在先明确退出。
- README/SKILL 改为第 0 步环境准备 + 第 1/2/3 步部署、验证。

## 2026-08-20 — vpnplus 初版（ACVPN 加固迁移）

本仓库由 [ccAzy/ACVPN](https://github.com/ccAzy/ACVPN) 迁移并加固而来。ACVPN 保持不动，此处为安全收敛版。

### 🛡️ 安全加固（相对 ACVPN 的核心差异）

- **独立防火墙命名链** — 关键修复
  - `ACVPN_ANTIPROBE`（filter INPUT）：防主动探测全部规则
  - `ACVPN_PORTHOP`（nat PREROUTING）：Hy2/Tuic 端口跳跃
  - `ACVPN_RSS`（filter INPUT）：RSS 相关（若有）
  - 主链仅一条跳转（`-I INPUT 1 -j ACVPN_ANTIPROBE`），重跑/卸载只 `-F/-X` 自己的链
  - **废除** 旧版 `grep 'limit: above'/'#conn'` 全局匹配删 INPUT 的写法 —— 该写法可能误删 fail2ban / Docker / 其他程序的安全规则
- **外部 sb.sh 锁定 + 强制校验**
  - 固定 commit `5001e76efc9e15eac1f8ff33a0b389172e331e1d`
  - SHA256 `65113dd45eba3bb377e71e89f01d77d84537757771802898acc6e60f36bf06be`
  - 下载后强制校验，失败即中止，不静默降级 → 防供应链篡改
- **内核 SHA256 强制校验**
  - SHA256SUMS 无法获取 / 找不到目标包 / 校验不匹配 → 一律中止安装
  - 不再"仅警告后照装"（内核为最高权限组件，不容无声降级）
  - 支持 `VERSION_PIN=x.y.z` 锁定版本
- **核心/可选失败语义分离**
  - 核心步骤（安装 sing-box / 生成订阅 / Argo）失败 → `DEPLOY_OK=false`，不写成功标记
  - 可选步骤（WARP / ethtool 不支持项 / IPv6 规则）失败 → 告警继续
- **精确进程清理**
  - busybox 按监听端口定位 PID 停止，废除 `pkill -x busybox` 杀全局
- **安全默认收紧**
  - `VMESS_LOCK` 默认 `on`（明文 VMess 端口公网 DROP，仅 Argo 回环可达），旧版默认 off
- **网络感知 sysctl**
  - `accept_ra` 仅在检测到无 IPv6 全局地址时才关闭，避免破坏依赖 RA 获址的 VPS
- **set -e 边界修复**
  - crontab/grep 命令替换统一 `|| true`，杜绝静默提前退出

### 🧰 可运维性

- **dry-run 模式** — deploy_optimize.sh / deploy_singbox.sh / cleanup.sh 均支持 `--dry-run` 预览
- **防火墙备份** — cleanup 前自动备份 iptables/ip6tables/nftables 规则到 `/var/backups/vpnplus/`
- **部署清单** — 内核来源/版本/SHA256 与 sb.sh commit/SHA256 写入 `/var/log/vpnplus-*-manifest.log`
- **verify.sh 对齐** — 改验独立命名链存在性，不再 grep 全局规则
- **`--force --dry-run`** — cleanup 支持非交互 + 预览组合

### 📄 文档

- README/SKILL 全面改写，新增"相对 ACVPN 的安全加固清单"
- 标记路径改为 `/etc/.vpnplus-optimized` / `/etc/.vpnplus-singbox`
- 服务/脚本改 vpnplus 命名（`vpnplus-argo-keepalive.sh`、`acvpn-rss.service` 沿用兼容旧清理）

## 兼容性说明

- 独立链名沿用 `ACVPN_*` 前缀，是为了兼容清理旧 ACVPN 安装部署的规则，属有意保留
- 升级外部 sb.sh 时**必须同时更新 `SB_COMMIT` 与 `SB_SHA256`**，否则校验失败拒绝安装
- 本仓库未继承 ACVPN 的 git 历史（新仓库独立起点）
