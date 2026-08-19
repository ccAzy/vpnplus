<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Debian%2FUbuntu-orange" alt="platform">
  <img src="https://img.shields.io/badge/kernel-BBRv3--max-blue" alt="bbrv3">
</p>

<h1 align="center">vpnplus</h1>
<p align="center"><strong>sing-box 一键部署的加固版。两条命令，安全落地。</strong></p>

---

## 是什么

vpnplus 基于 [ccAzy/ACVPN](https://github.com/ccAzy/ACVPN) 二次加固，把 **内核优化 + sing-box 部署 + 订阅生成** 打包成两条命令，并在安全边界上做了体系化收敛：

- 内核自动装上 BBRv3 + 网络/安全参数极限调优（按内存分级防 OOM）
- sing-box 自动配好五协议 + 端口跳跃 + Argo 隧道 + WARP 域名分流
- 订阅链接直接打印在终端，复制到客户端就能用
- **独立防火墙链**：重跑/卸载只动 vpnplus 自己的链，绝不误删 fail2ban / Docker 等第三方规则
- **外部脚本锁定 + 强制校验**：sb.sh 固定到 commit 并 SHA256 校验，失败即中止
- **安全默认**：明文 VMess 端口默认封锁公网（仅 Argo 回环可达）

> 基于 [甬哥 sing-box-yg](https://github.com/yonggekkk/sing-box-yg) 二次开发（自维护 fork [ccAzy/sing-box-yg](https://github.com/ccAzy/sing-box-yg)）。要求 Debian 11+ / Ubuntu 22.04+，公网 IPv4，≥ 512MB 内存。

---

## 开始使用

SSH 连上你的 VPS，按顺序执行下面三步。

### 第 0 步：准备环境（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/bootstrap.sh)
```

只准备 Debian/Ubuntu 的基础工具，不装内核、不改防火墙、不重启。会检查/安装：

```text
curl jq iproute2 iptables procps psmisc util-linux cron ethtool kmod ca-certificates
```

> 第 0 步本身也需要 `curl`。极简 VPS 若没有 curl，先手动执行：
> `apt-get update && apt-get install -y curl`
> 如果跳过第 0 步，`deploy_optimize.sh` 和 `deploy_singbox.sh` 也会各自再次尝试补齐依赖。

### 第 1 步：优化系统（自动重启）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_optimize.sh)
```

装上 BBRv3 极致内核，把 TCP/UDP 参数拉到极限。跑完 10 秒后自动重启。

> 2-5 分钟。SSH 断开是正常的，等 30 秒重新连。
> 预检场景可用 `--no-reboot` 跳过自动重启，稍后手动 `reboot`。
> 支持 `--dry-run` 预览、`VERSION_PIN=x.y.z` 锁定内核版本。
> 内核包 **强制** SHA256 校验，校验缺失/失败一律中止安装，不解降级。

### 第 2 步：部署 sing-box（重启后）

```bash
curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_singbox.sh | bash
```

安装 sing-box → 生成订阅 → 配端口跳跃 → 开 Argo 隧道 → 装 WARP 分流。

> 3-8 分钟。跑完后终端直接打印订阅链接。
> **sb.sh 锁定到固定 commit + SHA256 校验**，防供应链篡改。
> 重复执行**不会覆盖**现有配置（幂等设计）。
> 支持 `--dry-run` 预览；`VMESS_LOCK=off` 可显式放开明文 VMess 端口。

### 第 3 步：导入客户端

把第 2 步打印的链接粘贴到客户端（Clash Verge / Mihomo Party / sing-box 等），选节点，开代理。

> 旧服务器先清理残留：`bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/cleanup.sh)`（支持 `--force --dry-run`）

---

## 装了什么

| 做好的事情 | 你得到什么 |
|---|---|
| BBRv3 内核 + 网络参数调优 | 延迟更低、吞吐更大；缓冲区/连接跟踪表按内存自动分级（小内存防 OOM） |
| ethtool 网卡深度优化 | 环形缓冲 4096、硬件卸载（含 UDP 分段）、中断合并 16us；不支持自动跳过 |
| VLESS / VMess / Hysteria2 / Tuic5 / AnyTLS | 五协议同时在线，客户端任选 |
| Hysteria2(40000-42000) + Tuic5(43000-45000) 端口跳跃 | ISP 限制 UDP 端口时更难封锁 |
| Argo 临时隧道 | Cloudflare CDN 转发隐藏 IP；QUIC 优先自动回退；保活 watchdog 掉线自动拉起 |
| WARP 域名分流 | ChatGPT / Netflix / Google 等走 WARP 出口，解锁流媒体 |
| 订阅链接 | Clash YAML + Sing-box JSON + 通用聚合 |
| **独立防火墙链** | 全部 vpnplus 规则收敛到 `ACVPN_ANTIPROBE` / `ACVPN_PORTHOP` 命名链，主链仅一条跳转；重跑/卸载只删自己的链，第三方规则零触碰 |
| **外部脚本锁定** | `sb.sh` 固定 commit `5001e76` + SHA256 强制校验 |
| **安全默认** | 明文 VMess 端口默认封锁公网（`VMESS_LOCK=on`），仅 Argo 回环可达 |
| **精确进程清理** | busybox 按端口定位停止，绝不 `pkill -x busybox` 杀全局 |
| **网络感知加固** | 仅当无 IPv6 地址才关闭 RA，避免破坏依赖 RA 获址的 VPS |
| 部署清单 | 每次安装把来源/版本/校验值写入 `/var/log/vpnplus-*-manifest.log` 供审计 |

> 全部参数持久化（`/etc/sysctl.d/`、systemd drop-in），重启不丢。

---

## 怎么管理

部署完后用 `sb` 命令管理一切（换端口、换协议、刷新订阅 Token、开关 Argo、更新内核）。

一键验证部署：

```bash
SERVER_IP=你的IP bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/verify.sh)
```

自动检查 BBRv3 内核、进程、端口、**独立防火墙链**、Argo 隧道、订阅、域名分流。

彻底卸载：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/cleanup.sh)
```

清除 sing-box / Argo / 端口跳跃 / 订阅 / 部署标记，**只清理 vpnplus 自己的独立防火墙链**，并自动备份原规则到 `/var/backups/vpnplus/`。

---

## 相对 ACVPN 的安全加固清单

1. **防火墙独立命名链** — 旧版按 `limit: above` / `#conn` 全局匹配删除 INPUT 规则，可能误删 fail2ban / Docker 等第三方规则；现改为独立链 `ACVPN_ANTIPROBE`（filter INPUT）+ `ACVPN_PORTHOP`（nat PREROUTING），主链仅一条跳转，清理只删自己的链。
2. **外部脚本强制校验** — 旧版 `curl 分支/sb.sh | install` 无校验；现锁定 commit `5001e76` + SHA256，失败即中止。
3. **内核强制校验** — 旧版 SHA256SUMS 缺失时降级"仅警告后照装"；现校验缺失/失败一律中止（内核为最高权限组件）。
4. **核心/可选失败语义** — 核心步骤（安装/订阅/Argo）失败不再用 `|| true` 吞掉，未完全成功不写部署标记。
5. **精确进程清理** — `pkill -x busybox` 改为按监听端口定位 PID 停止。
6. **安全默认收紧** — `VMESS_LOCK` 默认 `on`（旧版默认 off 暴露明文端口）。
7. **网络感知 sysctl** — `accept_ra` 仅当无 IPv6 地址才关闭。
8. **set -e 边界** — crontab/grep 命令替换统一 `|| true`，杜绝静默提前退出。
9. **dry-run + 备份** — 两个部署脚本与清理脚本都支持 `--dry-run`；清理前自动备份防火墙规则。

---

## 遇到问题

### 第 1 步报错 "BBRv3 下载失败 / SHA256 校验失败"

**检查 /boot 空间**（需 >200MB）：
```bash
df -h /boot
dpkg --list | grep linux-image | awk '{print $2}'
apt-get autoremove --purge -y
```
然后删标记重跑：
```bash
rm -f /etc/.vpnplus-optimized
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_optimize.sh)
```
> SHA256 校验失败通常意味着下载损坏或被篡改，**不应绕过**。若持续失败，用 `VERSION_PIN=x.y.z` 指定版本重试。

### 新内核启动不了

重启时 VNC 连上服务器，grub 菜单选旧内核。进系统后：
```bash
rm -f /etc/.vpnplus-optimized
```
下次重跑会尝试最新版内核。

### 协议连不上

```bash
reboot     # 先重启，多数情况解决
# 如果还不行：
pgrep -f sing-box                 # 进程在不在
ss -tlnp | grep sing-box          # TCP 端口
ss -ulnp | grep sing-box          # UDP 端口
journalctl -u sb -n 50 --no-pager # 日志
```

### Argo 隧道不启动

```bash
cat /etc/s-box/argo.log | grep trycloudflare   # 看有没有 URL
printf "3\n3\n1\n1\n" | sb                      # 手动重配
```

### 强制重装

```bash
rm -f /etc/.vpnplus-optimized /etc/.vpnplus-singbox
```
然后重新执行第 1、2 步。

---

## 致谢

- [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) — sing-box 管理脚本
- [ccAzy/ACVPN](https://github.com/ccAzy/ACVPN) — 基础部署框架
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — BBRv3 自动编译内核
- [Cloudflare](https://www.cloudflare.com/) — Argo 隧道
