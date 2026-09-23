#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/common.sh — 统一日志/运行/清单，供所有部署脚本 source
# 保持幂等：重复 source 不重复定义
[ -n "${VPNPLUS_COMMON_LOADED:-}" ] && return 0
VPNPLUS_COMMON_LOADED=1

# 颜色与日志（若已定义则不覆盖）
RED=${RED:-'\033[0;31m'}; GREEN=${GREEN:-'\033[0;32m'}; YELLOW=${YELLOW:-'\033[1;33m'}; CYAN=${CYAN:-'\033[0;36m'}; WHITE=${WHITE:-'\033[1;37m'}; N=${N:-'\033[0m'}

# 统一日志函数（若外层已定义则保留外层）
if ! declare -F info >/dev/null 2>&1; then info()  { echo -e "${CYAN}[*]${N}   $*"; }; fi
if ! declare -F ok >/dev/null 2>&1; then ok()    { echo -e "${GREEN}[✓]${N}   $*"; }; fi
if ! declare -F warn >/dev/null 2>&1; then warn() { echo -e "${YELLOW}[!]${N}   $*"; }; fi
if ! declare -F fail >/dev/null 2>&1; then fail() { echo -e "${RED}[✗]${N}   $*"; }; fi

# 部署清单（若外层已定义 MANIFEST 则复用）
MANIFEST=${MANIFEST:-"/var/log/vpnplus-manifest.log"}
manifest() { echo "[$(date -Is)] $*" >> "$MANIFEST" 2>/dev/null || true; }

# DRY_RUN 感知的执行包装
if ! declare -F run >/dev/null 2>&1; then
run() {
    if ${DRY_RUN:-false}; then info "[dry-run] $*"; return 0; fi
    "$@" 2>/dev/null || true
}
fi

# 原子写入：先写同目录临时文件，内容非空才 mv 覆盖（chrony/iptables/systemd 类文件防写半截）。
# 用法: cmd | atomic_write /etc/x.conf [备份后缀]；已生成文件用 atomic_place <src> <target> [备份后缀]
if ! declare -F atomic_write >/dev/null 2>&1; then
atomic_write() {
    local target="$1" bak="${2:-}" tmp
    if ${DRY_RUN:-false}; then
        info "[dry-run] 原子写 $target"
        cat >/dev/null 2>&1 || true
        return 0
    fi
    mkdir -p "$(dirname "$target")" 2>/dev/null || true
    tmp="$(mktemp "${target}.vpnplus.XXXXXX" 2>/dev/null)" || {
        warn "原子写失败：无法在 $(dirname "$target") 建临时文件"
        cat >/dev/null 2>&1 || true
        return 1
    }
    if ! cat >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
        rm -f "$tmp" 2>/dev/null || true
        warn "原子写失败：内容为空或写入出错（$target 保持原样）"
        return 1
    fi
    atomic_place "$tmp" "$target" "$bak"
}
fi

if ! declare -F atomic_place >/dev/null 2>&1; then
atomic_place() {
    local src="$1" target="$2" bak="${3:-}"
    [ -s "$src" ] || {
        rm -f "$src" 2>/dev/null || true
        return 1
    }
    if [ -n "$bak" ] && [ -e "$target" ]; then
        cp -a "$target" "${target}.${bak}" 2>/dev/null || true
    fi
    chmod --reference="$target" "$src" 2>/dev/null || true
    chown --reference="$target" "$src" 2>/dev/null || true
    mv -f "$src" "$target"
}
fi

# 基础依赖（两阶段共用，含 chrony 时间同步）
# shellcheck disable=SC2034 # used by callers after source
BASE_PACKAGES=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)

# 日志落盘（若 /var/log 可写）
if [ -w /var/log ] && [ -d /var/log ] && [ -z "${VPNPLUS_COMMON_LOGGED:-}" ]; then
    LOG_FILE="/var/log/vpnplus-common.log"
    : > "$LOG_FILE" 2>/dev/null || true
    VPNPLUS_COMMON_LOGGED=1
fi
