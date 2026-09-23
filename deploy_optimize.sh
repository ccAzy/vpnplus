#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnplus — 服务器暴力优化脚本（BBRv3 + 网络极限压榨）
# 幂等设计：已优化过的服务器再次运行会自动跳过，不会重复重启
#
# 相对旧版 ACVPN 的关键改进：
#   1. 内核校验和为【尽力而为】：上游提供 SHA256SUMS 就比对，没有/对不上只告警，
#      绝不阻断安装（上游 byJoey/Actions-bbr-v3 → ccAzy fork 都不产出校验和）。
#      决策依据：2026-09-23 用户拍板「默认信任上游，不为其维护哈希」。
#   2. 内核下载地址锁定到明确的 release tag（可配置 VERSION_PIN），
#      不做"API 动态取最新"的不确定性拼接。
#   3. 所有命令替换统一 || true 防 set -e 静默退出。
#   4. 全程写部署清单 /var/log/vpnplus-optimize-manifest.log（来源/版本/校验值）。
#   5. 支持 --dry-run 预览 + --no-reboot。
#
# 用法: bash deploy_optimize.sh [--no-reboot] [--dry-run] [VERSION_PIN=x.y.z]
# 强制重跑: rm -f /etc/.vpnplus-optimized && bash deploy_optimize.sh
# ===================================================================
set -euo pipefail

# ── lib 加载（保持单文件可独立运行：lib 存在则 source，否则用内联兜底） ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in common time optimize; do
    if [ -f "$SCRIPT_DIR/lib/${_lib}.sh" ]; then
        source "$SCRIPT_DIR/lib/${_lib}.sh"
    elif [ -f "lib/${_lib}.sh" ]; then
        source "lib/${_lib}.sh"
    elif [ -f "/usr/local/lib/vpnplus/${_lib}.sh" ]; then
        source "/usr/local/lib/vpnplus/${_lib}.sh"
    fi
done

# ── 参数解析 ──
NO_REBOOT=false
DRY_RUN=false
FORCE=false
VERSION_PIN="" # 可选：锁定 BBRv3 版本 (如 7.3.2)
for arg in "$@"; do
    case "$arg" in
    --no-reboot) NO_REBOOT=true ;;
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    VERSION_PIN=*) VERSION_PIN="${arg#VERSION_PIN=}" ;;
    --help | -h)
        cat <<'HELP'
vpnplus deploy_optimize.sh — 服务器暴力优化（BBRv3 + 网络极限压榨）
用法: bash deploy_optimize.sh [--no-reboot] [--dry-run] [--force] [VERSION_PIN=x.y.z]
  --no-reboot            完成优化后不自动重启（手动 reboot 生效）
  --dry-run              只打印将执行的动作，不实际修改系统
  --force                已优化也重跑（覆盖安装，`bash <(curl ...) --force` 一键重跑）
  VERSION_PIN=x.y.z      锁定 BBRv3 内核版本；缺省时取 release 最新
HELP
        exit 0
        ;;
    esac
done

MANIFEST="/var/log/vpnplus-optimize-manifest.log"
MARK="/etc/.vpnplus-optimized"

# ── 日志落盘 ──
if [ -w /var/log ] && [ -d /var/log ]; then
    LOG_FILE="/var/log/vpnplus-optimize.log"
    : >"$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1 || true
fi

# 写部署清单（来源/版本/校验值，供审计）
manifest() { echo "[$(date -Is)] $*" >>"$MANIFEST" 2>/dev/null || true; }

cleanup() { rm -f /tmp/bbrv3.deb /tmp/bbrv3.sha256 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

UA="User-Agent: vpnplus-deploy"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
N='\033[0m'

info() { echo -e "${CYAN}[*]${N}   $*"; }
ok() { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
fail() { echo -e "${RED}[✗]${N}   $*"; }

if [ -n "$VERSION_PIN" ] && [[ ! "$VERSION_PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "VERSION_PIN 格式无效：$VERSION_PIN（应为 x.y.z，例如 7.3.2）"
    exit 2
fi

# dry-run 包装：--dry-run 时不执行副作用命令
run() {
    if $DRY_RUN; then
        info "[dry-run] $*"
        return 0
    fi
    "$@"
}

step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

# ── 环境预检 ──
check_env() {
    local fail_flag=0
    if ! command -v apt-get &>/dev/null; then
        fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"
        fail_flag=1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        fail "需要 root 权限运行"
        fail_flag=1
    fi
    local mem_kb mem_mb
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 768 ]; then
        warn "内存不足 768MB（当前 ${mem_mb}MB），BBRv3 内核安装可能失败"
    fi
    case "$(uname -m)" in x86_64 | aarch64) ;; *)
        fail "不支持的架构: $(uname -m)"
        fail_flag=1
        ;;
    esac
    if [ "$fail_flag" -eq 1 ]; then exit 1; fi
}

ARCH=$(uname -m)
HOSTNAME=$(hostname)
case "$ARCH" in x86_64) DEB_ARCH="amd64" ;; aarch64) DEB_ARCH="arm64" ;; *) DEB_ARCH="$ARCH" ;; esac

CUR_KERNEL=$(uname -r)

# ── 幂等检测（提前执行，无需联网/装依赖） ──
if $FORCE; then
    info "--force 已启用，强制重跑全流程"
    rm -f "$MARK" 2>/dev/null || true
fi
if [ -f "$MARK" ]; then
    if echo "$CUR_KERNEL" | grep -q "bbrv3"; then
        if $FORCE; then
            info "--force 已启用，忽略已生效标记，继续重跑"
        else
            logo=$(
                cat <<'EOF'
  ██╗   ██╗██████╗ ███╗   ██╗██╗   ██╗██████╗ ██╗     ██╗   ██╗███████╗
  ██║   ██║██╔══██╗████╗  ██║██║   ██║██╔══██╗██║     ██║   ██║██╔════╝
  ██║   ██║██████╔╝██╔██╗ ██║██║   ██║██████╔╝██║     ██║   ██║███████╗
  ╚██╗ ██╔╝██╔═══╝ ██║╚██╗██║██║   ██║██╔═══╝ ██║     ██║   ██║╚════██║
   ╚═╝ ╚═╝ ╚═╝     ╚═╝ ╚═╝╚═╝   ╚═╝╚══════╝ ╚██████╔╝███████╗███████║
                                            ╚═════╝ ╚══════╝╚══════╝╚══════╝
EOF
            )
            echo "$logo"
            echo -e "  ${WHITE}服务器: ${CYAN}$HOSTNAME${N}"
            echo -e "  ${WHITE}当前内核: ${GREEN}$CUR_KERNEL${N}"
            echo ""
            ok "BBRv3 已生效，无需再次执行"
            info "如需强制重新优化：bash deploy_optimize.sh --force"
            echo ""
            exit 0
        fi
    else
        warn "标记文件存在但内核未使用 BBRv3（可能已更新），重新执行优化"
        if $DRY_RUN; then
            info "[dry-run] 删除失效优化标记: $MARK"
        else
            rm -f "$MARK"
        fi
    fi
fi

# ── 依赖（bootstrap 的内置兜底；远程直接运行也能准备环境） ──
# curl 是下载本脚本前的引导依赖；进入脚本后同时补齐 jq、iproute2、iptables、
# procps、cron、ethtool 等第二阶段会用到的工具。缺包安装失败时明确中止，
# 不再“apt 失败后继续运行再静默报错”。
install_dependencies() {
    # netfilter-persistent 提供服务 iptables-persistent；logrotate 提供日志轮转；flock 属 util-linux
    local packages=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    [ "${#missing[@]}" -eq 0 ] && {
        ok "基础依赖已齐全"
        return 0
    }
    info "缺少依赖: ${missing[*]}"
    $DRY_RUN && {
        info "[dry-run] apt-get update && apt-get install -y ${missing[*]}"
        return 0
    }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        fail "apt-get update 失败，检查软件源/网络"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || {
        fail "依赖安装失败: ${missing[*]}"
        return 1
    }
    ok "基础依赖安装完成"
}

if ! declare -F ensure_time_sync >/dev/null 2>&1; then
    ensure_time_sync() {
        info "校准系统时间（chrony 国内源）..."
        if $DRY_RUN; then
            info "[dry-run] 将配置 chrony 并同步时间"
            return 0
        fi
        if ! dpkg-query -W -f='${Status}' chrony 2>/dev/null | grep -q 'install ok installed'; then
            warn "chrony 未安装，已在依赖阶段补齐"
        fi
        cat >/etc/chrony/chrony.conf <<'CHRONY'
pool ntp.aliyun.com iburst
pool ntp1.aliyun.com iburst
pool cn.pool.ntp.org iburst
pool pool.ntp.org iburst
makestep 1 3
rtcsync
CHRONY
        systemctl enable --now chrony 2>/dev/null || systemctl restart chrony 2>/dev/null || true
        timeout 15 chronyc makestep 2>/dev/null || timeout 15 ntpdate -u ntp.aliyun.com 2>/dev/null || true
        sleep 2
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
            ok "时间已同步（chrony Normal）"
        else
            chronyc tracking 2>&1 | head -5 || true
            warn "chrony 尚未 Normal，稍后将自动追上（已设 makestep 1 3）"
        fi
        if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then
            ok "System clock synchronized: yes"
        else
            info "timedatectl: $(timedatectl 2>/dev/null | grep -E 'synchronized|NTP' | tr '\n' ';')"
        fi
        manifest "time sync ensured via chrony"
    }
fi

# 先预检再访问 apt，避免非 Debian 系统在检查前就执行 apt-get。
check_env
if $DRY_RUN; then
    install_dependencies
    info "[dry-run] 环境预检完成；跳过内核下载、系统写入和重启"
    exit 0
fi
install_dependencies || exit 1
ensure_time_sync
# ── IPv4 优先（防 raw.githubusercontent 等 v6 黑洞导致 curl 卡 75s）── 幂等去重单行
ensure_gai_ipv4() {
    if grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && [ "$(grep -c '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null)" -eq 1 ]; then return 0; fi
    grep -v '^precedence ::ffff:0:0/96' /etc/gai.conf >/tmp/gai.clean 2>/dev/null || true
    cat /tmp/gai.clean >/etc/gai.conf 2>/dev/null || true
    echo 'precedence ::ffff:0:0/96 100' >>/etc/gai.conf 2>/dev/null
}
if grep -q '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null && [ "$(grep -c '^precedence ::ffff:0:0/96 100' /etc/gai.conf 2>/dev/null)" -eq 1 ]; then
    ok "gai.conf 已设 IPv4 优先"
else
    if $DRY_RUN; then
        info "[dry-run] 将写入 /etc/gai.conf：precedence ::ffff:0:0/96 100（IPv4 优先，去重单行）"
    else
        ensure_gai_ipv4 && ok "已设 IPv4 优先（/etc/gai.conf，去重单行）" || warn "写入 /etc/gai.conf 失败"
    fi
fi
for dep in curl jq git xz tmux ip iptables ss tc systemctl; do
    command -v "$dep" >/dev/null 2>&1 || {
        fail "关键命令缺失: $dep，请先执行 bootstrap.sh"
        exit 1
    }
done

PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null) ||
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null) ||
    PUBLIC_IP="unknown"
[ "$PUBLIC_IP" = "unknown" ] && warn "无法获取公网 IP，网络可能受限"

# ── BBRv3 内核安装 ──
# 下载地址优先：
#   1) 若 VERSION_PIN 指定 → 精确拼接该 tag 的下载 URL（无 API 不确定性）
#   2) 否则 → API 取最新 max tag
# 校验和：有就比对、没有就跳过（只告警，不阻断）
if ! declare -F install_bbrv3 >/dev/null 2>&1; then
    install_bbrv3() {
        if echo "$CUR_KERNEL" | grep -q "bbrv3"; then
            local cur_ver latest_tag latest_ver
            cur_ver=$(echo "$CUR_KERNEL" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
            latest_tag=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
                "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null |
                jq -r '.[].tag_name // empty' | grep -F 'max' | head -1 || true)
            latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            if [ -z "$latest_ver" ]; then
                ok "已是 BBRv3: $CUR_KERNEL（无法确认最新版本，跳过）"
                return 0
            elif [ "$cur_ver" = "$latest_ver" ]; then
                ok "已是最新 BBRv3: $CUR_KERNEL"
                return 0
            else
                warn "当前 $CUR_KERNEL，最新 ${latest_ver}，开始升级..."
            fi
        fi

        # 已装好、只差重启：直接跳过下载。否则会白下 141MB（2026-09-23 实测约 3 分钟）。
        local _installed_kernel="" _k
        for _k in /boot/vmlinuz-*bbrv3*; do
            [ -e "$_k" ] && {
                _installed_kernel="$_k"
                break
            }
        done
        if [ -n "$_installed_kernel" ]; then
            ok "BBRv3 内核已安装（$_installed_kernel），只差重启生效 —— 跳过下载"
            return 0
        fi

        info "获取 BBRv3 内核..."
        local TAG="" DOWNLOAD_URL="" api_json

        if [ -n "$VERSION_PIN" ]; then
            # 显式锁定版本：TAG = ${ARCH}-${VERSION}-max
            local arch_tag="$DEB_ARCH"
            [ "$DEB_ARCH" = "amd64" ] && arch_tag="x86_64"
            TAG="${arch_tag}-${VERSION_PIN}-max"
            info "锁定版本: $TAG"
            api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 30 \
                "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases/tags/${TAG}" 2>/dev/null || true)
            DOWNLOAD_URL=$(echo "$api_json" | jq -r '.assets[]?.browser_download_url // empty' |
                grep -F "linux-image-" | grep -F "joeyblog-bbrv3" | grep -F "$DEB_ARCH.deb" | head -1 || true)
        else
            # 默认：取最新 -max release
            api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
                "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null || true)
            DOWNLOAD_URL=$(echo "$api_json" | jq -r '.[].assets[]?.browser_download_url // empty' |
                grep -F "linux-image-" | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1 || true)
        fi

        [ -z "$DOWNLOAD_URL" ] && {
            fail "无法获取任何可用的 BBRv3 下载地址（API 与 kernel.org 均失败）"
            return 1
        }

        info "下载 BBRv3... ($(basename "$DOWNLOAD_URL"))"
        # 断点续传 + 停滞判定：固定 --max-time 在慢速链路必然失败（141MB@0.84MB/s 需 161s > 120s），
        # 且不带 -C - 的 --retry 会丢弃已下载字节重下（curl 的 "Throwing away N bytes"）。
        local _want _sz _i=0
        _want=$(curl -fsSLI -H "$UA" --connect-timeout 15 --max-time 30 "$DOWNLOAD_URL" 2>/dev/null |
            awk 'tolower($0) ~ /^content-length:/ {gsub(/[^0-9]/, "", $2); print $2}' | tail -1 || true)
        while [ "$_i" -lt 20 ]; do
            _i=$((_i + 1))
            # 上一次异常退出可能把文件写超（旧版带 --retry 的副作用）→ 删掉重下
            if [ -n "$_want" ] && [ "$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)" -gt "$_want" ]; then
                warn "本地 deb 比远端大（$(stat -c%s /tmp/bbrv3.deb)B > ${_want}B），删除重下"
                rm -f /tmp/bbrv3.deb
            fi
            # 刻意不加 --retry：curl 内部重试不重算续传偏移，会把数据从旧偏移再写一遍
            # → 文件写重/写坏。重试一律交给外层 while（每次重读文件大小、重算 Range）。
            if curl -fL# -H "$UA" -C - --connect-timeout 15 \
                --speed-limit 10240 --speed-time 60 -o /tmp/bbrv3.deb "$DOWNLOAD_URL"; then
                break
            fi
            _sz=$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)
            if [ -n "$_want" ] && [ "$_sz" = "$_want" ]; then break; fi
            warn "下载中断（已得 ${_sz}B${_want:+ / ${_want}B}），续传重试 ${_i}/20…"
            sleep 3
        done
        _sz=$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)
        if [ -n "$_want" ] && [ "$_sz" != "$_want" ]; then
            fail "BBRv3 下载不完整：${_sz}B / ${_want}B"
            return 1
        fi
        if [ "$_sz" -eq 0 ]; then
            fail "BBRv3 下载失败"
            return 1
        fi

        # ── 校验和：尽力而为，绝不阻断 ──
        # 上游（byJoey/Actions-bbr-v3 → ccAzy fork）都不产出 SHA256SUMS。
        # 原先把它设为强制 → 必然中止、内核永远装不上。2026-09-23 拍板：默认信任上游，
        # 降级为「有就比对、没有或对不上只告警」，不阻断安装，也不需要任何人维护哈希。
        local pkg_name sha_url expected actual
        pkg_name=$(basename "$DOWNLOAD_URL")
        sha_url="$(dirname "$DOWNLOAD_URL")/SHA256SUMS"
        actual=$(sha256sum /tmp/bbrv3.deb 2>/dev/null | awk '{print $1}' || true)
        if curl -fsSL -H "$UA" --retry 1 --max-time 15 -o /tmp/bbrv3.sha256 "$sha_url" 2>/dev/null && [ -s /tmp/bbrv3.sha256 ]; then
            expected=$(awk -v f="$pkg_name" '$2 == f || $2 == "*" f {print $1; exit}' /tmp/bbrv3.sha256 2>/dev/null || true)
            if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
                ok "SHA256 校验通过 ($actual)"
            else
                warn "SHA256 未通过比对（expected=${expected:-无} actual=${actual:-无}）—— 按既定策略继续安装"
            fi
        else
            warn "上游未提供 SHA256SUMS（已知情况）—— 跳过校验，继续安装"
        fi
        manifest "BBRv3 $pkg_name sha256=${actual:-unknown} url=$DOWNLOAD_URL"

        if ! run dpkg -i /tmp/bbrv3.deb; then
            run apt-get install -f -y -qq || true
            run dpkg -i /tmp/bbrv3.deb || {
                fail "BBRv3 安装失败"
                return 1
            }
        fi

        # 验证新内核文件已就位（防 dpkg 成功但未解包，重启后无法开机）
        local kernel_file
        kernel_file=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*bbrv3*' -print -quit 2>/dev/null || true)
        if [ -n "$kernel_file" ]; then
            ok "新内核文件已就位: $kernel_file"
        else
            fail "未检测到 bbrv3 内核文件，安装可能未生效，中止重启"
            return 1
        fi

        # grub 菜单可见（部分 VPS 默认 timeout=0）
        if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
            run sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/g' /etc/default/grub
            run update-grub || warn "update-grub 失败，GRUB 菜单可能未更新"
        fi
        rm -f /tmp/bbrv3.deb
        ok "BBRv3 已安装（重启后生效）"
    }
fi
# ── 网络优化（保持 ACVPN 的三级内存分级 + ethtool 尽力降级） ──
if ! declare -F apply_sysctl >/dev/null 2>&1; then
    apply_sysctl() {
        info "应用网络暴力优化..."
        local mem_kb mem_mb RMEM TCPMEM CONNTRACK_MAX CONNTRACK_HASH
        mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
        mem_mb=$((mem_kb / 1024))
        if [ "$mem_mb" -ge 8192 ]; then
            RMEM="134217728"
            TCPMEM="65536 262144 1048576" # ≥8GB，页数=256MB/1GB/4GB
        elif [ "$mem_mb" -ge 2048 ]; then
            RMEM="67108864"
            TCPMEM="32768 65536 131072" # 2-8GB，页数=128MB/256MB/512MB
        else
            RMEM="16777216"
            TCPMEM="16384 32768 65536" # <2GB，页数=64MB/128MB/256MB
        fi

        if [ "$mem_mb" -ge 8192 ]; then
            CONNTRACK_MAX=1000000
            CONNTRACK_HASH=262144
        elif [ "$mem_mb" -ge 2048 ]; then
            CONNTRACK_MAX=500000
            CONNTRACK_HASH=131072
        else
            CONNTRACK_MAX=130000
            CONNTRACK_HASH=32768
        fi

        if command -v modprobe >/dev/null 2>&1; then
            if ! run modprobe tcp_bbr; then
                warn "tcp_bbr 模块加载失败，BBR 可能不可用"
            fi
            run modprobe nf_conntrack || true
        fi
        # 开机也要有 nf_conntrack：否则 /etc/sysctl.d 里那行 nf_conntrack_max 在 boot 时写不进去。
        # 只写「真以模块形式存在」的情况：内建内核上写了会让 systemd-modules-load 开机报错。
        if modinfo -n nf_conntrack >/dev/null 2>&1; then
            mkdir -p /etc/modules-load.d 2>/dev/null || true
            atomic_write /etc/modules-load.d/vpnplus-conntrack.conf <<'MODS'
# vpnplus：让 nf_conntrack 开机加载，保证 net.netfilter.nf_conntrack_max 能应用
nf_conntrack
MODS
        else
            info "nf_conntrack 为内建（非模块），无需写 modules-load.d"
        fi
        if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
            if ! run bash -c "printf '%s\\n' '$CONNTRACK_HASH' > /sys/module/nf_conntrack/parameters/hashsize"; then
                warn "nf_conntrack hashsize 写入失败，连接跟踪仍使用内核默认桶数"
            fi
        fi

        local conf="/etc/sysctl.d/99-vpnplus-brutal.conf"
        run bash -c "cat > '$conf' <<'SYS'
# vpnplus 网络优化（按内存分级，防 OOM；tcp_mem 单位为内存页）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $RMEM
net.core.wmem_max = $RMEM
net.ipv4.tcp_rmem = 4096 87380 $RMEM
net.ipv4.tcp_wmem = 4096 65536 $RMEM
net.ipv4.tcp_mem = $TCPMEM
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_limit_output_bytes = 262144
net.core.netdev_max_backlog = 262144
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.ipv4.tcp_app_win = 0
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_retrans_collapse = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_comp_sack_nr = 3
net.core.optmem_max = 204800
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.busy_read = 50
net.core.busy_poll = 50
SYS"
        if ! run sysctl --system; then
            warn "sysctl --system 执行失败，部分网络参数可能未生效"
        fi
        manifest "conntrack max=$CONNTRACK_MAX hash=$CONNTRACK_HASH"
        # 回读校验：conntrack 是「写了不等于生效」的典型——模块没加载时 sysctl 会静默失败
        local _ck
        _ck=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
        if [ -n "$_ck" ] && [ "$_ck" = "$CONNTRACK_MAX" ]; then
            ok "网络参数已写入 $conf 并应用（conntrack=$CONNTRACK_MAX，按内存分级防 OOM）"
        else
            warn "conntrack 未生效：期望 $CONNTRACK_MAX，实得 ${_ck:-读不到}（已写 /etc/modules-load.d/vpnplus-conntrack.conf，重启后应自动生效）"
        fi
    }
fi
if ! declare -F apply_ethtool >/dev/null 2>&1; then
    apply_ethtool() {
        command -v ethtool >/dev/null 2>&1 || {
            info "ethtool 未安装，跳过网卡深度优化"
            return 0
        }
        local iface
        iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
        if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
            warn "无法识别默认网卡，跳过 ethtool"
            return 1
        fi
        run ethtool -G "$iface" rx 4096 tx 4096 || true
        run ethtool -K "$iface" tx-checksumming on rx-checksumming on || true
        run ethtool -K "$iface" tso on gso on gro on || true
        run ethtool -K "$iface" tx-udp-segmentation on || true
        run ethtool -C "$iface" adaptive-rx off adaptive-tx off || true
        run ethtool -C "$iface" rx-usecs 16 tx-usecs 16 || true
        ok "ethtool 深度优化完成（不支持的项已自动跳过）"
    }
fi
if ! declare -F apply_qdisc >/dev/null 2>&1; then
    apply_qdisc() {
        local iface
        iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
        if [ -z "$iface" ]; then
            warn "无法识别默认网卡，跳过 fq 队列调度"
            return 1
        fi
        if ! run tc qdisc replace dev "$iface" root fq; then
            warn "fq 队列调度应用失败，BBR 仍会运行但节奏控制可能不理想"
            return 1
        fi
        ok "fq 队列调度已应用到 $iface"
    }
fi
if ! declare -F boost_limits >/dev/null 2>&1; then
    boost_limits() {
        run bash -c "cat > /etc/security/limits.d/99-vpnplus.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 655360
* hard nproc 655360
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 655360
root hard nproc 655360
LIMITS"
        ok "资源限制已提升"
    }
fi
if ! declare -F apply_rss >/dev/null 2>&1; then
    apply_rss() {
        # 多队列网络调优：所有 RX/TX 队列的 RPS/XPS + ethtool + fq 持久化。
        run bash -c "cat > /usr/local/sbin/vpnplus-net-tuning.sh <<'TUNE'
#!/bin/bash
set -u

iface=\$(ip route 2>/dev/null | awk '/default/ {print \$5; exit}')
[ -n \"\$iface\" ] || { echo '[vpnplus-net-tuning] no default interface' >&2; exit 1; }
[ -d \"/sys/class/net/\$iface\" ] || { echo \"[vpnplus-net-tuning] interface not found: \$iface\" >&2; exit 1; }

cores=\$(nproc 2>/dev/null || echo 1)
if [ \"\$cores\" -ge 64 ]; then
    cpu_mask=ffffffffffffffff
else
    cpu_mask=\$(printf '%x' \$(( (1 << cores) - 1 )))
fi
rps_flow=\$((cores * 32768))

command -v ethtool >/dev/null 2>&1 && {
    ethtool -G \"\$iface\" rx 4096 tx 4096 2>/dev/null || true
    ethtool -K \"\$iface\" tx-checksumming on rx-checksumming on 2>/dev/null || true
    ethtool -K \"\$iface\" tso on gso on gro on 2>/dev/null || true
    ethtool -K \"\$iface\" tx-udp-segmentation on 2>/dev/null || true
    ethtool -C \"\$iface\" adaptive-rx off adaptive-tx off 2>/dev/null || true
    ethtool -C \"\$iface\" rx-usecs 16 tx-usecs 16 2>/dev/null || true
}

rx_count=0
for queue in /sys/class/net/\$iface/queues/rx-*; do
    [ -d \"\$queue\" ] || continue
    printf '%s\\n' \"\$cpu_mask\" > \"\$queue/rps_cpus\" 2>/dev/null || true
    printf '%s\\n' \"\$rps_flow\" > \"\$queue/rps_flow_cnt\" 2>/dev/null || true
    rx_count=\$((rx_count + 1))
done
for queue in /sys/class/net/\$iface/queues/tx-*; do
    [ -d \"\$queue\" ] || continue
    printf '%s\\n' \"\$cpu_mask\" > \"\$queue/xps_cpus\" 2>/dev/null || true
done

tc qdisc replace dev \"\$iface\" root fq 2>/dev/null || true
if [ \"\$rx_count\" -gt 0 ]; then
    sysctl -w net.core.rps_sock_flow_entries=\$((rx_count * rps_flow)) >/dev/null 2>&1 || true
fi
echo \"[vpnplus-net-tuning] applied iface=\$iface cores=\$cores rx_queues=\$rx_count mask=\$cpu_mask\"
TUNE
chmod +x /usr/local/sbin/vpnplus-net-tuning.sh
cat > /etc/systemd/system/vpnplus-net-tuning.service <<'UNIT'
[Unit]
Description=vpnplus persistent network tuning
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpnplus-net-tuning.sh
[Install]
WantedBy=multi-user.target
UNIT"
        run systemctl daemon-reload || true
        if ! run systemctl enable --now vpnplus-net-tuning.service; then
            warn "网络调优 systemd 服务启用失败，重启后可能不会自动恢复网卡参数"
        fi
        ok "多队列 RPS/XPS、ethtool、fq 已配置并持久化 (vpnplus-net-tuning.service)"
    }
fi
# ── GRUB 默认内核校验（防重启后进旧内核） ──
if ! declare -F ensure_grub_boot >/dev/null 2>&1; then
    ensure_grub_boot() {
        [ -f /boot/grub/grub.cfg ] || {
            warn "未找到 /boot/grub/grub.cfg，跳过默认内核校验"
            return 1
        }
        # 用「子菜单>条目」的完整路径定位 BBRv3，而不是数字索引（只数 menuentry 会算错，
        # 见 2026-09-23 实测：算出 index 1 而真实 index 1 是 Advanced 子菜单）。
        local path gd
        path=$(awk -F"'" '
            /^[[:space:]]*submenu /   { d++; st[d]=$2; next }
            /^[[:space:]]*menuentry / { if ($2 ~ /bbrv3/) { p=""; for (i=1;i<=d;i++) p=p st[i] ">"; print p $2; found=1; exit } next }
            /^\}/                     { if (d>0) d-- }
        ' /boot/grub/grub.cfg 2>/dev/null || true)

        if [ -z "$path" ]; then
            if grep -q 'vmlinuz-.*bbrv3' /boot/grub/grub.cfg 2>/dev/null; then
                warn "未解析出 BBRv3 独立菜单项（grub.cfg 里有 bbrv3 内核）；重启后用 uname -r 确认"
                return 0
            fi
            warn "grub.cfg 中未找到 BBRv3 菜单项"
            return 1
        fi

        gd=$(grep -oP '^GRUB_DEFAULT=\K.*' /etc/default/grub 2>/dev/null | head -1 || true)
        if [ "$gd" = "\"$path\"" ]; then
            ok "GRUB 默认引导项已指向 BBRv3（$path）"
            return 0
        fi

        local _esc="${path//&/\\&}"
        run sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$_esc\"|" /etc/default/grub
        if ! run update-grub; then
            warn "update-grub 失败，GRUB 默认项可能未保存"
            return 1
        fi
        ok "GRUB 默认引导项已设为 BBRv3：$path"
        local setdef
        setdef=$(grep -oP '^[[:space:]]*set default=\K.*' /boot/grub/grub.cfg 2>/dev/null | tail -1 || true)
        [ -n "$setdef" ] && info "grub.cfg: set default=$setdef"
        return 0
    }
fi
# ══════════ 主流程 ══════════
if $DRY_RUN; then echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"; fi
logo() { :; }

# check_env/install_dependencies 已在依赖阶段完成，这里不重复执行。

step "1" "清理旧安装"
if [ -f /etc/.vpnplus-singbox ]; then
    info "检测到 sing-box 已部署，跳过旧安装清理（保留 /etc/s-box）"
elif [ -f "$MARK" ]; then
    warn "检测到优化标记，跳过清理"
else
    run systemctl stop sb xr 2>/dev/null || true
    run systemctl disable sb xr 2>/dev/null || true
    run pkill -15 -f sing-box 2>/dev/null || true
    run pkill -15 -f xray 2>/dev/null || true
    sleep 2
    run pkill -9 -f sing-box 2>/dev/null || true
    run pkill -9 -f xray 2>/dev/null || true
    run rm -rf /etc/s-box /root/agsbx /usr/local/etc/argosbx \
        /etc/systemd/system/sb.service /etc/systemd/system/xr.service \
        /etc/systemd/system/cloudflared-argo.service 2>/dev/null || true
    run systemctl daemon-reload || true
    ok "清理完成"
fi

step "2" "BBRv3 内核安装"
BBR_OK=false
if install_bbrv3; then BBR_OK=true; else
    fail "BBRv3 安装失败（网络优化仍会继续，但不会写成功标记/重启）"
fi

step "3" "网络暴力优化"
apply_sysctl
apply_ethtool || warn "ethtool 优化已跳过（可选步骤，不影响后续步骤）"
apply_qdisc || true
boost_limits
apply_rss

if $BBR_OK; then
    ensure_grub_boot || warn "GRUB 默认引导项未确认；若重启后进入旧内核请手动处理"
    run touch "$MARK"
    manifest "optimize mark written; kernel=$CUR_KERNEL"
    step "4" "重启生效"
    echo ""
    if $NO_REBOOT || $DRY_RUN; then
        info "已跳过自动重启 (--no-reboot/--dry-run)"
        info "请稍后手动执行: reboot"
        info "重启后执行第 2 步: curl -fsSL .../deploy_singbox.sh | bash"
        exit 0
    fi
    for i in $(seq 10 -1 1); do
        echo -ne "  即将重启... ${i} 秒 \r"
        sleep 1
    done
    echo ""
    sync
    reboot
else
    echo ""
    warn "BBRv3 内核未安装成功，未写优化标记、未重启"
    info "网络优化已应用（重启后仍生效，但 BBRv3 需要内核安装成功）"
    info "修复后重新执行: bash deploy_optimize.sh"
    exit 1
fi
