# vpnplus Refactor Plan — A Conservative Split

> 设计来源: docs/superpowers/specs/2026-08-27-vpnplus-refactor-design.md
> 目标: a稳定 > c低成本变更 > b高效，保持一键裸装兼容，无版本号

## Task 1: lib/common.sh — 统一日志/运行/清单
- 抽取 RED/GREEN/YELLOW/CYAN, info/ok/warn/fail, manifest(), run(), trap, BASE_PACKAGES(含chrony)
- 验证: bash -n lib/common.sh && shellcheck lib/common.sh

## Task 2: lib/time.sh — 时间同步抽离
- 抽取 ensure_time_sync() / check_time_sync()（国内源 chrony + makestep + Leap Normal校验）
- 验证: bash -n, shellcheck, 手动 chronyc tracking

## Task 3: lib/firewall.sh — 防火墙与跳跃
- 抽取 persist_firewall(), clean_chains(), apply_antiprobe(), config_port_hopping()
- 常量 HOP_HY_RANGE/HOP_TU_RANGE/RATE_* 集中
- 验证: bash -n, shellcheck, verify.sh 中链存在检查

## Task 4: lib/singbox.sh — sing-box 安装与投喂
- 抽取 install_singbox_yg(), sb_feed(), assert_sb_menu(), apply_argo_patch()
- 验证: bash -n, shellcheck, dry-run 不卡死

## Task 5: lib/subscription.sh — 订阅
- 抽取 setup_subscription() 含 KEEP_PORT + RESET_SUB=1 轮转, get_sub_port(), wait_subscription(), ensure_sub_httpd()
- 验证: RESET_SUB=1 dry-run 删旧, 正常重跑复用

## Task 6: lib/argo.sh — Argo 隧道
- 抽取 start_argo(), install_argo_keepalive() v3 (flock/双检/翻滚冷却)
- 验证: bash -n, keepalive 脚本存在且 cron 注册

## Task 7: lib/warp.sh — WARP 与分流
- 抽取 setup_warp(), setup_domain_routing(), fix_mport_dup()
- 验证: sbwpph 存在性检查

## Task 8: 瘦身 deploy_optimize.sh
- 改为 source lib/common.sh lib/time.sh，保留编排：check_env -> install_deps -> ensure_time_sync -> bbr -> sysctl
- 删除重复的 BASE_PACKAGES/ensure_time_sync 定义
- 验证: bash -n, shellcheck, --dry-run 预览

## Task 9: 瘦身 deploy_singbox.sh
- 改为 source 7个 lib，瘦到 ~250行编排：ensure_time_sync -> sb -> subscription -> hopping -> argo -> firewall -> warp
- 保留 Thin 入口，对外参数 --dry-run/--reset-sub/VMESS_LOCK 兼容
- 验证: bash -n, shellcheck, main 流程可 --dry-run

## Task 10: 重构 verify.sh
- 拆 lib/verify/time.sh, tuic.sh, port.sh, subscription.sh, argo.sh
- 新增时间/TUIC污染/回环204 三检
- 验证: bash -n, 本机 verify.sh 通过 (rn1 54321)

## Task 11: bootstrap.sh 补 chrony
- PACKAGES 加 chrony，gai.conf 保持
- 验证: --check-only / --dry-run

## Task 12: 文档与收尾
- README: 更新 Tuic 54321, RESET_SUB, chrony 自检说明
- SKILL.md 同步
- CHANGELOG 不加版本号（按要求）
- 全量 bash -n + shellcheck + git diff --stat

## 验证清单
- [ ] 全脚本 bash -n 通过
- [ ] shellcheck 仅 patched_ok 一个可忽略 warning
- [ ] RN1 dry-run 5 脚本 + verify.sh 全绿
- [ ] git push 仅 4+lib 文件，无隐私
