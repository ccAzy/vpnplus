#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnplus — 环境准备与依赖检查
# 用法: bash bootstrap.sh [--dry-run] [--check-only]
#
# 只负责准备 Debian/Ubuntu VPS 的基础工具，不安装内核、不部署 sing-box、
# 不修改防火墙、不重启机器。
# ===================================================================
set -euo pipefail

DRY_RUN=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --check-only) CHECK_ONLY=true ;;
        --help|-h)
            cat <<'HELP'
vpnplus bootstrap.sh — 环境准备与依赖检查
用法: bash bootstrap.sh [--dry-run] [--check-only]
  --dry-run    只显示将安装的包，不修改系统
  --check-only 只检查，不执行 apt update/install
HELP
            exit 0 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
info(){ echo -e "${CYAN}[*]${N}   $*"; }
ok(){ echo -e "${GREEN}[✓]${N}   $*"; }
warn(){ echo -e "${YELLOW}[!]${N}   $*"; }
fail(){ echo -e "${RED}[✗]${N}   $*"; }

if [ "$(id -u)" -ne 0 ]; then fail "需要 root 权限：sudo bash bootstrap.sh"; exit 1; fi
if ! command -v apt-get >/dev/null 2>&1; then fail "仅支持 Debian/Ubuntu（未找到 apt-get）"; exit 1; fi
if ! command -v systemctl >/dev/null 2>&1; then fail "未找到 systemd/systemctl，不能部署 sing-box"; exit 1; fi

. /etc/os-release 2>/dev/null || true
case "${ID:-}" in
    debian|ubuntu|linuxmint|pop) info "发行版: ${PRETTY_NAME:-$ID}" ;;
    *) warn "未识别的 apt 发行版: ${PRETTY_NAME:-unknown}（继续前请确认兼容性）" ;;
esac

ARCH=$(uname -m)
case "$ARCH" in x86_64|aarch64) ok "架构支持: $ARCH" ;; *) fail "不支持的架构: $ARCH"; exit 1 ;; esac

MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
[ "$MEM_MB" -gt 0 ] && { info "内存: ${MEM_MB}MB"; [ "$MEM_MB" -lt 512 ] && warn "内存低于 512MB，BBRv3/Argo/WARP 可能不稳定"; }
BOOT_MB=$(df -Pm /boot 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "${BOOT_MB:-}" ] && [ "$BOOT_MB" -lt 200 ] && warn "/boot 可用空间低于 200MB（当前 ${BOOT_MB}MB）"

# 命令 -> Debian 包映射；这些包覆盖 vpnplus 两个部署阶段与 Hermes CLI 的基础环境。
PACKAGES=(
    ca-certificates curl jq git xz-utils tmux
    bash coreutils grep sed gawk
    iproute2 iptables iptables-persistent procps psmisc util-linux
    cron ethtool kmod logrotate
)

missing=()
for pkg in "${PACKAGES[@]}"; do
    case "$pkg" in
        ca-certificates|curl|jq|git|xz-utils|tmux|bash|coreutils|grep|sed|gawk|iproute2|iptables|iptables-persistent|procps|psmisc|util-linux|cron|ethtool|kmod|logrotate)
            # Debian 包名与命令不完全一一对应，按 dpkg 查询包是否安装
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg") ;;
    esac
done

if [ "${#missing[@]}" -eq 0 ]; then
    ok "基础依赖已齐全"
elif $CHECK_ONLY; then
    warn "缺少软件包: ${missing[*]}"
    exit 2
elif $DRY_RUN; then
    info "[dry-run] 将安装: ${missing[*]}"
else
    info "缺少软件包: ${missing[*]}"
    info "刷新软件源索引..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || { fail "apt-get update 失败，检查软件源/网络"; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || { fail "依赖安装失败: ${missing[*]}"; exit 1; }
    ok "基础依赖安装完成"
fi

# 非安装性检查：提前告诉用户第二阶段会用到的工具是否仍缺失。
commands=(curl jq git xz tmux bash ip ss iptables iptables-save iptables-restore ip6tables-restore systemctl crontab pgrep pkill timeout sha256sum sysctl flock logrotate)
missing_cmd=()
for cmd in "${commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_cmd+=("$cmd"); done
if [ "${#missing_cmd[@]}" -gt 0 ]; then
    warn "仍缺少命令: ${missing_cmd[*]}（可能由 VPS 镜像裁剪或包名差异造成）"
    $CHECK_ONLY && exit 2
else
    ok "部署所需基础命令已可用"
fi

info "bootstrap 只准备环境；下一步执行 deploy_optimize.sh"
