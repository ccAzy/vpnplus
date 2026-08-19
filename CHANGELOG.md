# Changelog

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
