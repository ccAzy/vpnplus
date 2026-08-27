<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Debian%2FUbuntu-orange" alt="platform">
  <img src="https://img.shields.io/badge/service-sing--box-blue" alt="sing-box">
</p>

<h1 align="center">vpnplus</h1>
<p align="center"><strong>新手友好的 sing-box VPS 一键部署脚本。</strong></p>

---

## 先看这里

vpnplus 用来在 Debian/Ubuntu VPS 上快速部署代理节点，并自动完成：

- BBRv3 和基础网络优化（幂等，重跑自动跳过）
- sing-box 节点安装
- VLESS、VMess、Hysteria2、Tuic5、AnyTLS 协议配置
- Hysteria2/Tuic5 端口跳跃（重跑前自动清理过期跳跃段 NAT 残留）
- Argo 临时隧道 + **三级自愈保活**：进程挂掉重启、隧道僵死探测后自动重连换新域名、新域名自动同步进订阅
- WARP 域名分流
- Clash/Mihomo、Sing-box 和通用订阅生成（**订阅端口重跑保持不变**，客户端地址长期有效）
- 防主动探测和安全清理

建议 VPS 至少有 1GB 内存。512MB 也可以尝试，但同时运行 BBRv3、Argo、WARP 和 sing-box 时更容易内存不足。

目标系统需要：

- Debian/Ubuntu 或兼容 apt 的系统
- root 权限
- systemd
- `x86_64` 或 `aarch64` 架构
- `/boot` 至少约 200MB 可用空间

---

## 三步一键部署

公开仓库后，三步命令都可以直接执行，不需要克隆仓库：

### 1. 准备环境

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/bootstrap.sh)
```

### 2. 优化系统

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_optimize.sh)
```

这一步会：

- 检查系统、架构、内存和 `/boot` 空间
- 安装并校验 BBRv3 内核
- 优化 TCP/UDP 和 fq
- 优化网卡和多队列
- 设置系统资源限制
- 检查 GRUB
- 默认自动重启 VPS

SSH 断开是正常现象。重启后重新连接即可。

不想自动重启时：

```bash
bash deploy_optimize.sh --no-reboot
```

只想检查参数和环境：

```bash
bash bootstrap.sh --check-only
bash bootstrap.sh --dry-run
bash deploy_optimize.sh --dry-run
```

需要锁定 BBRv3 内核版本时：

```bash
bash deploy_optimize.sh VERSION_PIN=x.y.z
```

内核下载失败、SHA256 校验失败或校验文件缺失时，脚本会停止，不会强行安装。

### 3. 重启后部署 sing-box

服务器重启后重新 SSH 登录，再执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_singbox.sh)
```

脚本会自动安装 sing-box、生成订阅、配置端口跳跃、Argo、WARP 和防火墙规则。完成后会直接在终端打印订阅链接。

把打印出的订阅链接导入以下客户端即可：

- Clash Verge / Mihomo Party / Karing / V2rayN
- sing-box 客户端
- 其他支持对应订阅格式的客户端

---

## 默认设置：不启用防火墙

默认情况下：

```text
VMESS_LOCK=off
```

明文 VMess 端口直接暴露公网（配合密钥登录/关闭密码登录已足够安全，不需要防火墙锁端口）。适合使用 6688 等非默认 SSH、仅密钥登录、无其他暴露面、希望节点全通的场景。

如果你希望额外启用防主动探测（封锁明文 VMess 公网端口，仅 Argo 回环可达）：

```bash
VMESS_LOCK=on bash deploy_singbox.sh
```

---

## 部署后检查

本机检查：

```bash
bash verify.sh
```

从公网检查订阅：

```bash
SERVER_IP="你的服务器IP" bash verify.sh
```

检查内容包括：

- **时间同步**：`chrony Leap Normal` / `System clock synchronized` / `ntpdate` 偏移（P0，Reality/VMess 对时）
- sing-box 是否安装和运行
- BBRv3 是否存在
- fq 和网卡优化状态
- 持久化网络调优服务
- TCP/UDP 端口监听
- 端口跳跃链（含 `DNAT 指向` 是否对准当前 TUIC 端口）
- **PREROUTING 是否有残留过期端口跳跃段**（防止 hy2/tuic 端口跳跃握手无响应）
- **TUIC 单点污染**：`40254` 已知污染端口黄灯 + `127.0.0.1 TUIC 回环 204` 自检（区分本机坏 vs 外网墙）
- 防主动探测链
- VMess 明文端口锁定（默认 off，开启时才会检查）
- Argo 隧道（HTTP 4xx 视为可达，仅超时才报不可达，避免误报）
- 三种订阅链接（含订阅端口是否可访问）
- WARP 域名分流文件

---

## 管理节点

部署完成后可以使用：

```bash
sb
```

通过 `sb` 可以管理协议、端口、订阅、Argo、WARP 和 sing-box 服务。

网络调优服务：

```bash
systemctl status vpnplus-net-tuning.service
journalctl -u vpnplus-net-tuning.service --no-pager
```

部署日志：

```text
/var/log/vpnplus-optimize.log
/var/log/vpnplus-optimize-manifest.log
/var/log/vpnplus-singbox-manifest.log
```

---

## 强制重跑部署

需要重新执行一遍 sing-box 部署（如更换配置、恢复现场状态）时：

```bash
rm -f /etc/.vpnplus-singbox && bash deploy_singbox.sh
```

脚本已处理重跑稳定性的几个坑：

- **不会卡死**：sb 菜单投喂有 timeout + 结束清理残留进程兜底
- **订阅端口保持不变**：重跑复用已有订阅端口，客户端订阅地址长期有效（`RESET_SUB=1` 强制轮转除外）
- **幂等清理跳跃段 NAT 残留**：重跑前自动清掉过期端口跳跃规则，不影响 hy2/tuic
- **时间自动对准**：首次部署即装 `chrony` 国内源（阿里云/cn.pool），`verify.sh` 会验 `Leap Normal`，杜绝 `bad timestamp` 全不通
- **重复跑安全**：BBRv3 等系统优化幂等，已生效自动跳过

### 订阅暴露后一键轮转

默认重跑会**复用**旧订阅（`http://IP:port/token` 不变）。若链接暴露想换新：

```bash
RESET_SUB=1 bash deploy_singbox.sh
# 或 bash deploy_singbox.sh --reset-sub
```
旧链接立即 `404`，新订阅 `clmi.yaml/tuic5.txt` 已切到新 `token/端口`，TUIC 当前为 `54321`（`40254` 已知易被限速，`verify.sh` 会黄灯提醒）

## 项目结构（lib 化，低成本变更）

源码以 `lib/` 为准，单文件保持 `curl | bash` 兼容：

```
lib/common.sh      # 日志/颜色/BASE_PACKAGES+chrony
lib/time.sh        # ensure_time_sync / check_time_sync
lib/optimize.sh    # BBRv3 + sysctl/ethtool/qdisc（按内存分级）
lib/firewall.sh    # ACVPN_* 链 + 跳跃 DNAT + 清理
lib/singbox.sh     # sb_feed / sb 安装
lib/subscription.sh# KEEP_PORT + RESET_SUB
lib/argo.sh        # Argo + keepalive v3
lib/warp.sh        # WARP + 分流
lib/verify/        # verify 侧 time/tuic 回环 204
build.sh           # 校验 lib→单文件漂移，生成 dist/ 供 raw 分发
```
改 1 个端口/1 个协议只动 1 个 `lib/*.sh`，`bash build.sh` 校验漂移，`bash -n + shellcheck` 门禁。

---

## Argo 临时隧道自动恢复

Argo 临时隧道（trycloudflare.com 域名）掉线或僵死时，服务器上的保活脚本（每 3 分钟）会自动处理：

1. cloudflared 进程挂掉 → 自动重启
2. 进程在但隧道探测无响应（连续两次 HTTP 失败，防误判）→ 判定僵死 → 自动重连
3. 重连后换新域名 → 自动刷新本地订阅（jhsub/clmi/sbox 全部指向新域名）

> 注意：临时隧道换域名后，客户端需要**重新拉一次订阅**才能拿到新域名。期望域名永久不变的话，可使用 Cloudflare 固定隧道（sb 菜单 3 → 3 → 2）。

---

## 旧服务器清理

清理前建议先预览：

```bash
bash cleanup.sh --force --dry-run
```

确认无误后执行：

```bash
bash cleanup.sh --force
```

交互式清理：

```bash
bash cleanup.sh
```

清理脚本会先把防火墙规则备份到：

```text
/var/backups/vpnplus/
```

它只清理 vpnplus 自己的配置、服务、订阅进程、网络调优服务和 `ACVPN_*` 独立防火墙链，不会按关键词全局删除 Docker、fail2ban 或其他程序的规则。

---

## 常见问题

### BBRv3 安装失败

先检查 `/boot`：

```bash
df -h /boot
dpkg --list | grep linux-image
```

然后可以删除标记重试：

```bash
rm -f /etc/.vpnplus-optimized
bash deploy_optimize.sh
```

不要绕过 SHA256 校验。

### 协议连接不上

```bash
pgrep -af sing-box
ss -tlnp | grep sing-box
ss -ulnp | grep sing-box
journalctl -u sb -n 100 --no-pager
bash verify.sh
```

如果只是公网连接失败，还要检查云厂商安全组、VPS 防火墙、运营商线路和端口限制。

### 订阅更新失败

```bash
cat /etc/s-box/subport.log
cat /etc/s-box/subtoken.log
ss -tlnp | grep busybox
curl -v http://127.0.0.1:订阅端口/token/clmi.yaml
```

如果本机能访问、手机不能访问，通常是运营商拦截高端口 HTTP 订阅或公网防火墙限制。

---

## 重要限制

- 服务器优化不能保证所有运营商线路都变快；绕路、丢包、拥塞和商家限速需要实际测速。
- Argo 临时隧道没有固定 SLA，不等于永久稳定线路（已有自动保活，换域名后客户端需重新拉订阅）。
- WARP 和域名分流属于可选增强功能，失败不一定代表核心节点部署失败。
- Swap 主要用于小内存 VPS 防止 OOM，不会直接提升网速。
- 已在真实 VPS（Debian 12 / HK）端到端验证：5 个直连协议（vless/vmess/anytls/hy2/tuic）+ Argo 临时隧道节点客户端均可连通。

---

## 感谢

vpnplus 在以下项目和服务的基础上进行集成、改造和安全加固：

- [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) — sing-box 管理脚本和部署思路
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) — BBRv3 内核项目上游
- [ccAzy/Actions-bbr-v3](https://github.com/ccAzy/Actions-bbr-v3) — 当前脚本使用的 BBRv3 Release 派生仓库
- [Cloudflare](https://www.cloudflare.com/) — Argo 隧道和 WARP 服务

感谢上游项目和相关服务。vpnplus 主要增加了固定提交校验、强制 SHA256、独立防火墙链、精确清理、默认安全策略、动态多队列调优和部署后验证。

---

## 许可证

GPLv3
