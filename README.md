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

- BBRv3 和基础网络优化
- sing-box 节点安装
- VLESS、VMess、Hysteria2、Tuic5、AnyTLS 协议配置
- Hysteria2/Tuic5 端口跳跃
- Argo 临时隧道
- WARP 域名分流
- Clash/Mihomo、Sing-box 和通用订阅生成
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

- Clash Verge / Mihomo Party
- sing-box 客户端
- 其他支持对应订阅格式的客户端

> 当前仓库暂时是 Private，公开前远程命令会返回 HTTP 404。临时使用本地文件方式：
>
> ```bash
> cd /path/to/vpnplus
> bash bootstrap.sh
> bash deploy_optimize.sh
> # 重启并重新连接后：
> bash deploy_singbox.sh
> ```

---

## 默认安全设置

默认情况下：

```text
VMESS_LOCK=on
```

明文 VMess 端口不会直接暴露公网，只允许 Argo 回环访问。

如果你明确需要开放明文 VMess：

```bash
VMESS_LOCK=off bash deploy_singbox.sh
```

不建议新手关闭这个保护。

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

- sing-box 是否安装和运行
- BBRv3 是否存在
- fq 和网卡优化状态
- 持久化网络调优服务
- TCP/UDP 端口监听
- 端口跳跃链
- 防主动探测链
- VMess 明文端口锁定
- Argo 隧道
- 三种订阅链接
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
- Argo 临时隧道没有固定 SLA，不等于永久稳定线路。
- WARP 和域名分流属于可选增强功能，失败不一定代表核心节点部署失败。
- Swap 主要用于小内存 VPS 防止 OOM，不会直接提升网速。
- 完整的 BBRv3、sing-box、Argo、WARP 和客户端连通性仍需在真实 VPS 上验证。

---

## 感谢

vpnplus 在以下项目和服务的基础上进行集成、改造和安全加固：

- [yonggekkk/sing-box-yg](https://github.com/yonggekkk/sing-box-yg) — sing-box 管理脚本和部署思路
- [Actions-bbr-v3](https://github.com/ccAzy/Actions-bbr-v3) — BBRv3 内核构建与 Release 来源
- [Cloudflare](https://www.cloudflare.com/) — Argo 隧道和 WARP 服务

感谢上游项目的工作。vpnplus 主要增加了固定提交校验、强制 SHA256、独立防火墙链、精确清理、默认安全策略、动态多队列调优和部署后验证。

---

## 许可证

GPLv3
