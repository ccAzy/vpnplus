---
name: vpnplus
description: >
  基于 ccAzy/ACVPN 二次加固的 sing-box 一键部署指南。安全收敛：独立防火墙链/外部脚本锁定+SHA256校验/核心可选失败语义/精确进程清理/网络感知加固。
  Use when the user asks to deploy sing-box, set up a VPN/VPS proxy node, configure Vless/Hysteria2/Tuic5/Vmess protocols, set up local IP subscriptions, Argo tunnels, domain split routing, or push node subscriptions to Telegram.
---

# vpnplus — Sing-box VPN 部署流程（加固版）

## 文件总览

| 文件 | 用途 |
|------|------|
| `SKILL.md` | 本文件 — 完整部署指南 |
| `bootstrap.sh` | **部署前置** — 基础依赖安装与环境检查（不改防火墙/不重启） |
| `deploy_optimize.sh` | **第1步** — BBRv3 强制校验 + TCP/UDP + ethtool + 动态 RPS/XPS/fq + 自动重启 |
| `deploy_singbox.sh` | **第2步** — sing-box 部署（独立防火墙链 + 订阅 + Argo + WARP） |
| `cleanup.sh` | 独立清理脚本（只删 vpnplus 自己的防火墙链，自动备份） |
| `verify.sh` | 部署后验证（进程/端口/BBR/fq/网卡/独立链/Argo/订阅/域名分流） |

## 核心安全设计（相对 ACVPN 的关键差异）

1. **独立防火墙链**：所有 vpnplus 规则收敛到 `ACVPN_ANTIPROBE`（filter INPUT）+ `ACVPN_PORTHOP`（nat PREROUTING）命名链，主链仅一条跳转（`-I INPUT 1 -j ACVPN_ANTIPROBE`）。重跑/卸载只 `-F/-X` 自己的链，绝不用 `limit: above`/`#conn` 全局匹配删 INPUT 规则 → 保护 fail2ban/Docker 等第三方规则。
2. **外部脚本锁定**：sb.sh 固定 commit `5001e76efc9e15eac1f8ff33a0b389172e331e1d` + SHA256 `65113dd45eba3bb377e71e89f01d77d84537757771802898acc6e60f36bf06be`，失败即中止。
3. **内核强制校验**：SHA256SUMS 缺失/失败 → 中止，不降级照装。
4. **核心/可选失败语义**：`install_singbox_yg`/`setup_subscription`/`start_argo` 失败记入 `DEPLOY_OK=false`，未完全成功不写 `/etc/.vpnplus-singbox`。
5. **精确进程清理**：busybox 按监听端口定位 PID 停止，不 `pkill -x busybox` 杀全局。
6. **默认不启用防火墙**：`VMESS_LOCK` 默认 `off`（明文 VMess 端口公网直连，适合密钥登录+关闭密码登录、无多余暴露面的节点全通场景）。需要防主动探测时设 `VMESS_LOCK=on`（明文 VMess 公网 DROP，仅 Argo 回环可达）。
7. **网络感知 sysctl**：仅当无 IPv6 全局地址才关 `accept_ra`。
8. **dry-run + 备份**：两部署脚本 + cleanup 均支持 `--dry-run`；cleanup 前自动备份规则到 `/var/backups/vpnplus/`。
9. **conntrack 协同调优**：`nf_conntrack_max` 按内存分级，并在模块支持时同步 hashsize，避免只增大表上限而放大桶冲突。
10. **iptables 持久化双保险**：端口跳跃/防探测规则除 netfilter-persistent 外，额外落盘 `/etc/iptables/rules.v4|v6` 并注册 `vpnplus-netfilter-restore.service`（network-pre.target 前恢复），防重启后 `ACVPN_*` 链丢失。
11. **Argo 保活 v3**：flock 互斥 + 进程口径统一（`cloudflared+tunnel+--url`）+ cloudflared 路径自动探测 + 翻动检测冷却（防域名无限漂移）；纯单引号 heredoc 直写，消除 bash -c 双层转义风险。
12. **sb.sh 哈希复审**：重跑时即使 sb 存在也校验哈希（原版或补丁白名单 `SB_PATCH_MARKER`），不在可信集合则重新下载。
13. **IPv4 锁定（入口+出口）**：入口IP（订阅 `server:`）走 `SB 15-1` 切换最稳（`sb` 管理 `server_ip.log`）；出口 `route.rules[].strategy / dns / outbounds direct/socks.domain_strategy` 仅 `--force` 时原子 `jq` 改 `ipv4_only`（带备份校验），平时 `verify.sh` 只读告警，不再每次强写库。
14. **gai/legacy 兼容**：`gai.conf precedence ::ffff:0:0/96 100` 去重单行幂等，`sing-box 1.12+ legacy` 前置 `Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true` 防 `FATAL` 重启风暴。

## 部署流程（从第一步开始）

### 部署前置：准备环境

```bash
bash bootstrap.sh
# 只检查，不安装：
bash bootstrap.sh --check-only
# 预览待安装包：
bash bootstrap.sh --dry-run
```

`bootstrap.sh` 只检查/安装 Debian/Ubuntu 基础工具：`curl`、`jq`、`git`、`xz-utils`、`tmux`、`iproute2`、`iptables`、`procps`、`psmisc`、`util-linux`、`cron`、`ethtool`、`kmod`、`ca-certificates`。其中 `git`/`xz-utils` 供 Hermes 安装器使用，`tmux` 用于 SSH 断开后保持 Agent 会话。不装内核、不改防火墙、不写 sing-box 配置、不重启。

> 部署前置本身需要 curl。极简 VPS 没有 curl 时，先执行：
> `apt-get update && apt-get install -y curl`
> 跳过部署前置也可以：两个部署脚本会各自兜底安装依赖。

### 第 1 步：暴力优化 + BBRv3（强制校验） + 重启

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_optimize.sh)
```

自动完成：
1. 清理旧 sing-box 残留（保留已部署的 /etc/s-box）
2. 安装 BBRv3 内核（**SHA256 强制校验**，缺失/失败即中止）
3. 应用网络优化（TCP/UDP 缓冲、BBR/fq、所有 RX/TX 队列的 RPS/XPS、ethtool，按内存分级防 OOM）
4. 提升系统资源限制（nofile/nproc）
5. 校验 GRUB 默认引导新内核
6. 10 秒后自动重启（`--no-reboot` 可跳过）

> 参数：
> - `--no-reboot` 跳过自动重启
> - `--dry-run` 预览不执行
> - `VERSION_PIN=x.y.z` 锁定 BBRv3 版本

### 第 2 步：部署 sing-box（重启后）

```bash
curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_singbox.sh | bash
```

自动完成：
1. 安装 sing-box-yg 管理脚本（**锁定 commit + SHA256 校验**，重跑亦复审哈希）
2. 配置订阅链接（Clash / Sbox / 通用聚合）
3. 配置 Hysteria2 端口跳跃（40000-42000）+ Tuic 端口跳跃（43000-45000）→ 独立链 `ACVPN_PORTHOP`
4. 启动 Argo 临时隧道（Cloudflare CDN 隐藏 IP）+ **三级保活 v3**（flock 互斥/进程+HTTP双检/僵死重连/翻动冷却）
5. 应用安全加固（独立链 `ACVPN_ANTIPROBE` + 网络感知 sysctl + **iptables 双保险持久化**）
6. WARP + 域名分流（可选，失败不影响核心）
7. 日志轮转（`/etc/logrotate.d/vpnplus`）

### 第 3 步：协议不通？重启服务器

```bash
reboot
```
重启后等待 1-2 分钟，重新测试协议。

## 部署前清理旧安装

```bash
bash cleanup.sh          # 交互式（需确认）
bash cleanup.sh --force  # 非交互
bash cleanup.sh --dry-run # 预览
```

> cleanup 只删 vpnplus 自己的 `ACVPN_ANTIPROBE`/`ACVPN_PORTHOP`/`ACVPN_RSS` 链，并清理 `vpnplus-net-tuning.service` 与其调优脚本；自动备份原规则到 `/var/backups/vpnplus/`。crontab/grep 用 `|| true` 防 set -e 静默退出。

## 部署后验证

```bash
SERVER_IP="<服务器IP>" bash verify.sh
# 或本机（不传 IP 时测 127.0.0.1）
bash verify.sh
```

## 部署清单（审计日志）

每次部署的关键动作记录到：
- `/var/log/vpnplus-optimize-manifest.log`（内核来源/版本/SHA256）
- `/var/log/vpnplus-singbox-manifest.log`（sb.sh commit/SHA256、部署结果、VMESS_LOCK 值）

## 管道命令速查

| 步骤 | 命令 | 校验 |
|------|------|------|
| 清理 | `bash cleanup.sh --force` | `[ ! -d /etc/s-box ]` |
| 第1步 | `bash deploy_optimize.sh` | 重启后 `uname -r` 含 `bbrv3` |
| 第2步 | `curl .../deploy_singbox.sh \| bash` | `which sb && [ -d /etc/s-box ]` |
| 订阅 | `printf "3\n8\n1\n\n\n0\n0\n" \| sb` | `[ -f /etc/s-box/subport.log ]` |
| Hysteria2 | `printf "4\n3\n2\n40000:42000\n0\n" \| sb` | `ss -ulnp \| grep sing-box` |
| Argo | `printf "3\n3\n1\n1\n0\n" \| sb` | `grep trycloudflare /etc/s-box/argo.log` |
| 域名分流 | `printf "5\n3\n1\n域名列表\n0\n0\n" \| sb` | `[ -f /etc/s-box/sbwpph.json ]` |
| 验证 | `SERVER_IP=<IP> bash verify.sh` | 全部通过 |

## 备注

- 本仓库是加密壳：真正执行 sing-box 安装的是外部 `sb.sh`。**升级外部依赖时须同时更新 `SB_COMMIT` 与 `SB_SHA256` 两个常量**，否则校验失败拒绝安装（这是防供应链篡改的有意设计）。
- 独立防火墙链名沿用 `ACVPN_*` 前缀是为了兼容清理旧 ACVPN 安装，属有意保留，勿改。
