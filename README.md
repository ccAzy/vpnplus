<p align="center">
  <img src="https://img.shields.io/badge/license-GPLv3-green" alt="license">
  <img src="https://img.shields.io/badge/platform-Debian%2FUbuntu-orange" alt="platform">
  <img src="https://img.shields.io/badge/service-sing--box-blue" alt="sing-box">
</p>

<h1 align="center">vpnplus</h1>
<p align="center"><strong>面向 VPS 的 sing-box 节点部署、网络优化与安全清理工具。</strong></p>

---

## 这是什么

vpnplus 将以下工作整合成一套可重复执行的 Bash 流程：

- Debian/Ubuntu VPS 环境准备
- BBRv3 内核安装与强制 SHA256 校验
- BBR + fq + TCP/UDP 参数优化
- 按内存分级的网络缓冲和连接跟踪表
- 动态 RX/RPS 与 TX/XPS 多队列调优
- ethtool 网卡参数与 systemd 开机持久化
- sing-box 协议部署、订阅生成和节点管理
- Hysteria2/Tuic5 端口跳跃
- Argo 临时隧道与掉线保活
- WARP 域名分流
- 独立防火墙链、防主动探测和安全清理
- 部署后检查、订阅 HTTP 实测和卸载验证

它不会承诺“所有线路都自动变快”。服务器参数只能改善 VPS 侧的处理能力；运营商绕路、国际出口拥塞、VPS 商家限速和移动网络 QoS，仍然需要用真实测速区分。

---

## 文件结构

| 文件 | 作用 |
|---|---|
| `bootstrap.sh` | 部署前置：检查/安装基础依赖，不装内核、不部署 sing-box、不重启 |
| `deploy_optimize.sh` | 系统与网络优化：BBRv3、TCP/UDP、ethtool、RPS/XPS、fq、资源限制、GRUB |
| `deploy_singbox.sh` | sing-box 部署：协议、订阅、端口跳跃、Argo、WARP、防火墙和保活 |
| `verify.sh` | 部署后检查：进程、端口、防火墙链、Argo、订阅、域名分流 |
| `cleanup.sh` | 安全清理：备份规则、停止服务、删除自身配置并验证结果 |
| `SKILL.md` | 面向 Agent 的部署和排障说明 |

---

## 使用前提

目标机器需要：

- Debian/Ubuntu 系 apt 环境
- root 权限
- systemd
- `x86_64` 或 `aarch64` 架构
- 公网 IPv4 更容易完成订阅和节点连接
- 建议至少 1GB 内存；512MB 也可尝试，但 BBRv3、Argo、WARP 同时运行时更容易出现内存压力
- `/boot` 至少保留约 200MB 可用空间，用于内核安装

当前仓库如果保持 Private，VPS 不能匿名读取 `raw.githubusercontent.com`。请先将仓库目录上传到 VPS，或使用已认证的 Git 方式克隆；不要把 GitHub Token 直接写进命令行。

以下命令均假设你已经进入仓库目录：

```bash
cd /path/to/vpnplus
```

---

## 三步部署

### 第一步：准备环境

```bash
bash bootstrap.sh
```

它会检查/安装：

```text
curl jq git xz-utils tmux bash coreutils grep sed gawk
iproute2 iptables procps psmisc util-linux cron ethtool kmod ca-certificates
```

不会执行：

- 内核安装
- 防火墙改动
- sing-box 配置
- 系统重启

预览或只检查：

```bash
bash bootstrap.sh --dry-run       # 只显示缺少的软件包
bash bootstrap.sh --check-only   # 只检查，不执行 apt update/install
```

极简系统没有 curl 时，需要先手动准备：

```bash
apt-get update && apt-get install -y curl
```

### 第二步：系统与网络优化

```bash
bash deploy_optimize.sh
```

执行流程：

```text
环境预检
→ 清理旧 sing-box 残留
→ 获取 BBRv3 内核包
→ 强制 SHA256 校验
→ dpkg 安装并检查内核文件
→ 写入网络参数
→ 应用 BBR/fq
→ 应用 ethtool
→ 配置所有 RX/RPS 与 TX/XPS 队列
→ 创建开机持久化网络调优服务
→ 提升 nofile/nproc
→ 检查 GRUB 默认内核
→ 写入成功标记
→ 10 秒后重启
```

支持参数：

```bash
bash deploy_optimize.sh --no-reboot
bash deploy_optimize.sh --dry-run
bash deploy_optimize.sh VERSION_PIN=x.y.z
```

- `--no-reboot`：完成优化后不自动重启
- `--dry-run`：只做环境预检和动作预览，不执行内核安装及系统写入
- `VERSION_PIN=x.y.z`：锁定指定内核版本，格式必须是数字版本号

内核包下载失败、SHA256SUMS 缺失或校验失败时，脚本会中止，不会无校验安装。

### 第三步：重连后部署 sing-box

服务器重启后重新 SSH 登录，然后执行：

```bash
bash deploy_singbox.sh
```

它会依次尝试完成：

1. 下载并校验固定提交的外部管理脚本
2. 自动安装 sing-box
3. 生成 Clash/Mihomo、Sing-box 和通用聚合订阅
4. 配置 Hysteria2 端口跳跃：`40000-42000`
5. 配置 Tuic5 端口跳跃：`43000-45000`
6. 创建独立端口跳跃链 `ACVPN_PORTHOP`
7. 配置 Argo 临时隧道
8. 配置 Argo 保活和订阅刷新
9. 配置 WARP 域名分流
10. 创建独立防探测链 `ACVPN_ANTIPROBE`
11. 启动订阅 HTTP 服务
12. 在终端打印最终订阅链接

支持：

```bash
bash deploy_singbox.sh --help
bash deploy_singbox.sh --dry-run
VMESS_LOCK=on bash deploy_singbox.sh
VMESS_LOCK=off bash deploy_singbox.sh
```

`VMESS_LOCK` 默认是 `on`：明文 VMess 端口不直接暴露公网，仅允许 Argo 回环入口。只有明确需要时才使用 `off`。

---

## 网络优化具体做了什么

### BBR 与 fq

配置并尝试加载：

```text
modprobe tcp_bbr
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

同时运行时对默认网卡执行 `tc qdisc replace ... root fq`。

### TCP/UDP 参数

包括：

- TCP/UDP 读写缓冲区
- `tcp_mem` 内存页分级
- TCP 自动接收缓冲
- TCP metrics 策略
- 输出队列限制
- TCP Fast Open
- keepalive
- 丢包恢复和 SACK 相关参数
- `netdev_max_backlog`、`somaxconn`、SYN backlog

`tcp_mem` 会根据内存分级，避免把小内存 VPS 配置成不合理的超大 TCP 内存上限。

### 多队列与网卡

第一次部署和每次开机都会尝试：

- ethtool 环形缓冲
- TSO/GSO/GRO
- UDP 分段卸载
- 中断合并
- 所有 RX 队列的 RPS
- 所有 TX 队列的 XPS
- 按 CPU 数量生成 CPU mask
- 默认网卡 fq 队列

持久化文件：

```text
/usr/local/sbin/vpnplus-net-tuning.sh
/etc/systemd/system/vpnplus-net-tuning.service
```

可用以下命令查看：

```bash
systemctl status vpnplus-net-tuning.service
journalctl -u vpnplus-net-tuning.service --no-pager
```

不支持的网卡能力会被跳过并给出提示；不同 VPS 的虚拟网卡、CPU 数量和队列数不同，实际收益需要测速确认。

---

## 部署后验证

本机验证：

```bash
bash verify.sh
```

从外部地址验证订阅：

```bash
SERVER_IP="你的服务器IP" bash verify.sh
```

验证内容包括：

- `sb` 命令和 sing-box 二进制
- `/etc/s-box` 配置目录
- BBRv3 模块提示
- sing-box 进程
- TCP/UDP 监听端口
- `ACVPN_PORTHOP` 端口跳跃链
- `ACVPN_ANTIPROBE` 防探测链
- Argo URL 和 HTTP 端点
- 三种订阅格式的 HTTP 状态
- 域名分流文件和规则数量

最终会输出通过/失败数量；存在失败项时退出码为 `1`。

注意：本机验证主要检查 `127.0.0.1`；要验证公网访问，必须传入 `SERVER_IP`。

---

## 管理与审计

部署完成后可以使用外部管理命令：

```bash
sb
```

常见管理内容包括：

- 更换端口
- 更换协议
- 刷新订阅 Token
- 开关 Argo
- 更新或重配 sing-box
- 配置订阅和域名分流

审计日志：

```text
/var/log/vpnplus-optimize.log
/var/log/vpnplus-optimize-manifest.log
/var/log/vpnplus-singbox-manifest.log
```

清单会记录内核来源、版本、SHA256、外部脚本校验结果和部署状态。

---

## 安全清理

交互式清理：

```bash
bash cleanup.sh
```

非交互清理：

```bash
bash cleanup.sh --force
```

只预览：

```bash
bash cleanup.sh --force --dry-run
```

清理前会备份防火墙规则到：

```text
/var/backups/vpnplus/
```

清理范围包括：

- sing-box、Argo 和 vpnplus 网络调优服务
- 订阅 BusyBox httpd
- vpnplus 自己的 cron 条目
- vpnplus 自己的 systemd unit
- `/etc/s-box`、订阅文件和部署标记
- vpnplus 写入的 sysctl 文件
- `ACVPN_ANTIPROBE`、`ACVPN_PORTHOP`、`ACVPN_RSS` 独立链
- vpnplus 相关 nftables 表

不会按通用关键词全局删除第三方防火墙规则，也不会全局杀掉所有 busybox 进程。

---

## 故障排查

### BBRv3 下载或校验失败

先检查：

```bash
df -h /boot
dpkg --list | grep linux-image
```

然后可以锁定一个已知版本重试：

```bash
rm -f /etc/.vpnplus-optimized
bash deploy_optimize.sh VERSION_PIN=x.y.z
```

不要绕过 SHA256 校验。

### 新内核启动失败

通过 VPS 控制台/VNC 选择旧内核进入系统，然后删除标记：

```bash
rm -f /etc/.vpnplus-optimized
```

确认 `/etc/default/grub` 和 `/boot` 状态后再重试。

### 协议无法连接

```bash
pgrep -af sing-box
ss -tlnp | grep sing-box
ss -ulnp | grep sing-box
journalctl -u sb -n 100 --no-pager
bash verify.sh
```

如果只有公网访问失败，重点检查：

- 云厂商安全组
- VPS 防火墙
- 运营商 TCP/UDP 限制
- 端口跳跃范围
- Argo 状态
- IPv4/IPv6 路由

### 订阅无法更新

```bash
cat /etc/s-box/subport.log
cat /etc/s-box/subtoken.log
ss -tlnp | grep busybox
curl -v http://127.0.0.1:订阅端口/token/clmi.yaml
systemctl status vpnplus-net-tuning.service
```

移动网络可能拦截高端口 HTTP 订阅；这种情况优先使用 Argo/HTTPS 入口，而不是反复重装 sing-box。

---

## 已知限制

- Private GitHub 仓库不能被 VPS 匿名 `curl` 读取；需要先上传代码或使用已认证的 Git 访问。
- BBRv3 内核安装依赖目标架构、发行版、`/boot` 空间和外部 Release 可用性。
- Argo 临时隧道没有固定 SLA，适合临时入口，不等于永久稳定线路。
- WARP、域名分流和 Argo 属于增强功能，失败时不一定代表核心 sing-box 部署失败。
- `ethtool`、RPS/XPS 和 fq 的效果取决于 VPS 虚拟网卡、CPU、宿主机和运营商线路。
- Swap 不会直接提升网速；如需增加 Swap，应把它作为小内存 VPS 的防 OOM 选项，而不是网络加速开关。
- 脚本已完成本地语法、ShellCheck 和生成脚本检查；完整 BBRv3、sing-box、Argo、WARP、客户端连通性仍需在真实 VPS 上端到端验证。

---

## 许可证

GPLv3
