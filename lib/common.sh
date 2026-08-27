#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/common.sh — 统一日志/运行/清单，供所有部署脚本 source
# 保持幂等：重复 source 不重复定义

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

# 基础依赖（两阶段共用，含 chrony 时间同步）
# shellcheck disable=SC2034 # used by callers after source
BASE_PACKAGES=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)

# 日志落盘（若 /var/log 可写）
if [ -w /var/log ] && [ -d /var/log ] && [ -z "${VPNPLUS_COMMON_LOGGED:-}" ]; then
    LOG_FILE="/var/log/vpnplus-common.log"
    : > "$LOG_FILE" 2>/dev/null || true
    VPNPLUS_COMMON_LOGGED=1
fi
