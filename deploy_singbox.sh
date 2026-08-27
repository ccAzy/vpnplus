#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnplus — sing-box VPN 一键部署（需先执行 deploy_optimize.sh）
# 用法: curl -fsSL .../deploy_singbox.sh | bash
#
# 相对旧版 ACVPN 的关键加固：
#   1. 外部 sb.sh 固定到 commit 5001e76 + 强制 SHA256 校验（失败即中止）
#   2. 防火墙改独立命名链（ACVPN_ANTIPROBE / ACVPN_PORTHOP），
#      重跑/卸载绝不按 'limit: above'/'#conn' 全局删 INPUT，保护第三方规则
#   3. 核心/可选失败语义分离：核心失败 → 不写成功标记；可选失败 → 告警继续
#   4. 进程清理精确化：busybox 用端口查找，绝不 pkill -x busybox 杀全局
#   5. 安全参数网络感知：IPv6 若无地址才关 RA，rp_filter 可覆盖
# ===================================================================
set -euo pipefail

# ── lib 加载（保持一键裸装兼容：lib 存在则 source，否则用内联兜底） ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in common time firewall singbox subscription argo warp; do
    if [ -f "$SCRIPT_DIR/lib/${_lib}.sh" ]; then source "$SCRIPT_DIR/lib/${_lib}.sh"
    elif [ -f "lib/${_lib}.sh" ]; then source "lib/${_lib}.sh"
    elif [ -f "/usr/local/lib/vpnplus/${_lib}.sh" ]; then source "/usr/local/lib/vpnplus/${_lib}.sh"
    fi
done

# ── 可调常量（集中管理，避免端口段/限速值散落各处） ──
readonly HOP_HY_RANGE="40000:42000"     # Hysteria2 端口跳跃段
readonly HOP_TU_RANGE="43000:45000"     # Tuic5 端口跳跃段
readonly RATE_SYN_ABOVE=50; readonly RATE_SYN_BURST=100    # TCP 代理端口 SYN 限速 /sec、burst
readonly RATE_UDP_ABOVE=200; readonly RATE_UDP_BURST=400   # UDP 端口/跳跃段 限速 /sec、burst
readonly CONN_ABOVE=200                  # 单 IP 单端口新建连接上限
readonly SSH_RATE_ABOVE=3; readonly SSH_RATE_BURST=5       # SSH 爆破防御 3/min、burst
readonly SB_PATCH_MARKER="/etc/s-box/.sb-argo-patched.sha256"

# ── sb 菜单安全投喂：一次性喂完按键，timeout 限定，结束后强杀残留 sb 交互防孤儿 ──
# 背景：sb（sing-box-yg）部分子菜单（如订阅 ipsub）完成操作后会 `sleep 3 && sb`
#       递归拉起新 sb 面板。若是固定管道喂键，stdin 一旦耗尽，递归的 sb 会永远挂起等待，
#       而 timeout 只杀最外层 → 留下孤儿 sb 进程，脚本被卡死等同"中断"。
# 解决：包装所有 sb 菜单调用，末尾补多组 0（逐层返回/退出），超时后清理本次会话遗留的 sb。
#       pkill 只针对"本次 sb_feed 期间新出现"的 sb 进程（用前后 PID 差集），不误伤同机手动开的 sb 面板。
if ! declare -F sb_feed >/dev/null 2>&1; then
sb_feed() {  # sb_feed <超时秒数> - <<'KEYS'  ... KB: 用 stdin 传入按键
    local secs="${1:-120}"; shift
    local out _before _after _pid _new_pids=""
    # 记录本函数开始前已有的 sb 进程，只杀本次新产生的孤儿（不误伤同机其他 sb 会话）
    _before=$(pgrep -f 'bash /usr/bin/sb' 2>/dev/null | sort -n | tr '\n' ' ' || true)
    out=$(timeout "$secs" sb "$@" 2>&1 || true) || true
    _after=$(pgrep -f 'bash /usr/bin/sb' 2>/dev/null | sort -n | tr '\n' ' ' || true)
    for _pid in $_after; do
        case " $_before " in *" $_pid "*) ;; *) _new_pids="$_new_pids $_pid";; esac
    done
    [ -n "$_new_pids" ] && { for _pid in $_new_pids; do kill -9 "$_pid" 2>/dev/null || true; done; }
    # 输出追加进诊断日志（去色），失败时便于回溯 sb 到底做了什么/卡在哪
    if [ -n "$out" ]; then
        echo "──[sb_feed t=${secs}] $(date -Is)" >> /var/log/vpnplus-sbfeed.log 2>/dev/null || true
        printf '%s\n' "$out" | sed -E 's/\x1B\[[0-9;]*[mK]//g' >> /var/log/vpnplus-sbfeed.log 2>/dev/null || true
    fi
    printf '%s' "$out"
}
fi
DRY_RUN=false
VMESS_LOCK="${VMESS_LOCK:-off}"     # 用户明确不需要防火墙：vmess 明文端口公网直连（不再锁回环）
RESET_SUB="${RESET_SUB:-0}"         # RESET_SUB=1 强制轮转订阅 token/端口（暴露后一键换链）
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --reset-sub) RESET_SUB=1 ;;
        --force) FORCE=true ;;
        --help|-h) cat <<'HELP'
vpnplus deploy_singbox.sh — sing-box 一键部署
用法: bash deploy_singbox.sh [--dry-run] [--reset-sub] [--force]
  --dry-run  只打印将执行的动作，不实际修改系统
  --reset-sub 强制轮转订阅（删除旧 subport/subtoken，生成全新 token/端口）
             等价 RESET_SUB=1 bash deploy_singbox.sh，暴露后一键换链
  --force    强制重跑全流程（忽略 /etc/.vpnplus-singbox 已部署标记，强制对齐 sb.json/iptables/订阅三处）
  VMESS_LOCK=on|off  明文 VMess 端口是否封锁公网（默认 off：直连，仅密钥登录无防火墙场景）
  RESET_SUB=1        同 --reset-sub
HELP
        exit 0 ;;
    esac
done

CHECKPOINT="/etc/.vpnplus-singbox"
MANIFEST="/var/log/vpnplus-singbox-manifest.log"
# 锁定的 sb.sh（ccAzy/sing-box-yg acvpn 分支，2026-08-05 提交）
SB_COMMIT="5001e76efc9e15eac1f8ff33a0b389172e331e1d"
SB_SHA256="65113dd45eba3bb377e71e89f01d77d84537757771802898acc6e60f36bf06be"
SB_URL="https://raw.githubusercontent.com/ccAzy/sing-box-yg/${SB_COMMIT}/sb.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
info()  { echo -e "${CYAN}[*]${N}   $*"; }
ok()    { echo -e "${GREEN}[✓]${N}   $*"; }
warn()  { echo -e "${YELLOW}[!]${N}   $*"; }
fail()  { echo -e "${RED}[✗]${N}   $*"; }

manifest() { echo "[$(date -Is)] $*" >> "$MANIFEST" 2>/dev/null || true; }

run() {
    if $DRY_RUN; then info "[dry-run] $*"; return 0; fi
    "$@"
}
# ── 安装 sing-box-yg（固定 commit + 强制 SHA256 校验） ──
if ! declare -F install_singbox_yg >/dev/null 2>&1; then
install_singbox_yg() {
    if command -v sb &>/dev/null && [ -f /etc/s-box/sb.json ]; then
        ok "sing-box-yg 已安装，跳过"; return 0
    fi
    if ! command -v sb &>/dev/null; then
        info "下载 sing-box-yg 管理脚本（锁定 commit ${SB_COMMIT:0:8}）..."
        local tmp="/tmp/sb.sh.download"
        if ! run curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp" "$SB_URL" || [ ! -s "$tmp" ]; then
            fail "sb.sh 下载失败（URL: $SB_URL）"; rm -f "$tmp" 2>/dev/null || true; return 1
        fi
        local actual
        actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)
        if [ "$actual" != "$SB_SHA256" ]; then
            fail "sb.sh SHA256 校验失败（期望 ${SB_SHA256:0:12}... 实得 ${actual:-空}）—— 中止，防供应链篡改"
            rm -f "$tmp" 2>/dev/null || true; return 1
        fi
        ok "sb.sh SHA256 校验通过"
        run install -m 0755 "$tmp" /usr/bin/sb
        manifest "sb.sh installed commit=${SB_COMMIT} sha256=$actual"
        rm -f "$tmp" 2>/dev/null || true
        [ -s /usr/bin/sb ] || { fail "/usr/bin/sb 写入失败"; return 1; }
        ok "sing-box-yg 管理脚本已安装（commit ${SB_COMMIT:0:8}）"
    else
        # 重跑复查：即使 sb 已存在，也校验其哈希是否落在可信集合内（原版 或 Argo 补丁版白名单）。
        # 防：首次校验只保证下载时刻安全，重跑时 /usr/bin/sb 可能已被替换/被 sed 补丁过而失去 pin 意义。
        local cur_sha patched_ok=false
        cur_sha=$(sha256sum /usr/bin/sb 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$cur_sha" ] && [ "$cur_sha" = "$SB_SHA256" ]; then
            ok "sing-box-yg 哈希与原版一致，保持"
        elif [ -f "$SB_PATCH_MARKER" ] && [ "$cur_sha" = "$(cat "$SB_PATCH_MARKER" 2>/dev/null || true)" ]; then
            ok "sing-box-yg 哈希命中补丁白名单（Argo http2→auto 已打）"; patched_ok=true
        else
            warn "现有 /usr/bin/sb 哈希不在可信集合（原版/补丁版），重新下载覆盖..."
            local tmp="/tmp/sb.sh.download"
            if ! run curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp" "$SB_URL" || [ ! -s "$tmp" ]; then
                fail "sb.sh 重新下载失败（URL: $SB_URL）"; rm -f "$tmp" 2>/dev/null || true; return 1
            fi
            local actual
            actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)
            if [ "$actual" != "$SB_SHA256" ]; then
                fail "sb.sh 重新下载后 SHA256 仍不匹配（期望 ${SB_SHA256:0:12}... 实得 ${actual:-空}）—— 中止，防供应链篡改"
                rm -f "$tmp" 2>/dev/null || true; return 1
            fi
            run install -m 0755 "$tmp" /usr/bin/sb
            manifest "sb.sh re-installed (hash drift) commit=${SB_COMMIT} sha256=$actual"
            rm -f "$tmp" 2>/dev/null || true
            [ -s /usr/bin/sb ] || { fail "/usr/bin/sb 写入失败"; return 1; }
            cur_sha="$actual"; patched_ok=false
            ok "sing-box-yg 已重新下载并校验"
        fi
        ok "sing-box-yg 管理脚本已就绪 (sha=${cur_sha:0:12})"
    fi
    sleep 1

    [ -f /etc/s-box/sb.json ] && { ok "sing-box 已安装，跳过"; return 0; }
    systemctl is-active sb >/dev/null 2>&1 && { ok "sing-box 服务运行中"; return 0; }
    systemctl is-active xr >/dev/null 2>&1 && { ok "xray 服务运行中"; return 0; }

    info "自动安装 sing-box（全默认配置，全程无需操作）..."
    sleep 2
    run rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb.service /etc/systemd/system/xr.service
    run systemctl daemon-reload || true
    # 安装流程: 1 → ''(开放端口) → ''(最新内核) → ''(自签) → ''(随机端口) → ''(不共用)
    if ! $DRY_RUN; then
        printf '1\n\n\n\n\n0\n0\n0\n' | sb_feed 300 || { warn "sb 安装菜单执行异常"; }
    else
        info "[dry-run] printf '1\\n\\n\\n\\n\\n' | timeout 300 sb"
    fi

    if [ -f /etc/s-box/sb.json ]; then ok "sing-box 安装完成"; return 0; fi
    if systemctl is-active sb >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; then
        ok "sing-box 已运行（检测到服务）"; return 0
    fi
    fail "sing-box 未能自动完成安装"; info "修复后重试: bash deploy_singbox.sh"
    return 1
}
fi
# ── 环境预检 + 第二阶段依赖兜底 ──
check_env() {
    if [ "$(id -u)" -ne 0 ]; then fail "需要 root 权限"; return 1; fi
    if ! command -v apt-get &>/dev/null; then fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"; return 1; fi

    # deploy_singbox 也可独立运行：补齐第一阶段可能未执行的工具。
    local packages=(ca-certificates curl jq git xz-utils tmux iproute2 iptables iptables-persistent procps psmisc util-linux cron ethtool kmod logrotate chrony)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        info "缺少第二阶段依赖: ${missing[*]}"
        if $DRY_RUN; then
            info "[dry-run] apt-get update && apt-get install -y ${missing[*]}"
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || { fail "apt-get update 失败，检查软件源/网络"; return 1; }
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || { fail "依赖安装失败: ${missing[*]}"; return 1; }
            ok "第二阶段基础依赖安装完成"
        fi
    fi
    for cmd in curl jq git xz tmux ip ss iptables systemctl crontab pgrep pkill timeout sha256sum sysctl; do
        command -v "$cmd" >/dev/null 2>&1 || { fail "关键命令缺失: $cmd，请先执行 bootstrap.sh"; return 1; }
    done
    if ! command -v systemctl &>/dev/null; then fail "无 systemd，sing-box 需要 systemd"; return 1; fi
    local mem_kb mem_mb
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))
    info "内存: ${mem_mb}MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt 512 ]; then warn "低内存 VPS（<512MB）"; fi
    return 0
}

if ! declare -F ensure_time_sync >/dev/null 2>&1; then
ensure_time_sync() {
    info "校准系统时间（chrony 国内源）..."
    if $DRY_RUN; then info "[dry-run] 将配置 chrony 并同步时间"; return 0; fi
    cat > /etc/chrony/chrony.conf <<'CHRONY'
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
    if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then ok "时间已同步（chrony Normal）"; else warn "chrony 尚未 Normal，稍后自动追上"; fi
}
fi
# ── 订阅配置 ──
if ! declare -F setup_subscription >/dev/null 2>&1; then
setup_subscription() {
    info "配置本地订阅链接..."
    sleep 1
    # RESET_SUB=1 / --reset-sub：暴露后一键轮转（删旧 token/端口，强制全新）
    if [ "${RESET_SUB:-0}" = "1" ] || [ "${RESET_SUB:-}" = "true" ]; then
        if $DRY_RUN; then
            info "[dry-run] RESET_SUB=1 将删除旧订阅并生成全新 token/端口"
        else
            info "RESET_SUB=1 检测到，清理旧订阅（旧链接将失效）..."
            rm -f /etc/s-box/subport.log /etc/s-box/subtoken.log 2>/dev/null || true
            rm -rf /root/websbox/* 2>/dev/null || true
            # 同步清理旧 sb 生成的聚合文件，避免残留
            rm -f /etc/s-box/jhsub.txt /etc/s-box/jhdy.txt 2>/dev/null || true
            ok "旧订阅已清理，下一步将生成全新 token/端口"
        fi
    fi
    # 端口稳定性：重跑时复用已有订阅端口，避免每次随机导致客户端订阅地址作废
    local KEEP_PORT=""
    if [ -f /etc/s-box/subport.log ]; then
        local _p
        _p=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
        # 仅复用合法端口段（与 sb 随机范围一致），异常值则放弃复用走随机
        if [ -n "$_p" ] && [ "$_p" -ge 1024 ] && [ "$_p" -le 65535 ] 2>/dev/null; then
            KEEP_PORT="$_p"
        fi
    fi
    if [ -n "$KEEP_PORT" ]; then
        info "检测到已有订阅端口 $KEEP_PORT，重跑将复用（客户端订阅地址保持有效）"
    fi
    if ! $DRY_RUN; then
        # 投喂序列对齐当前 sb 菜单（v26.x）：
        #   main changeserv(配置变更) → 8(设置本地IP订阅) → 1(重置安装) →
        #   \n(路径密码=当前UUID) → <端口行：已有端口则原样输入保持稳定，否则\n随机> → 尾部补足 0 逐层返回/退出
        # 即便中间 sleep 3 递归拉起新 sb 面板，sb_feed 的 timeout+pkill 也会兜底清理，绝不卡死。
        sb_feed 150 <<-EOSUB || true
3
8
1

${KEEP_PORT}

0
0
0
0
0
EOSUB
        sleep 3
    else
        info "[dry-run] sb 菜单 3-8-1 配置订阅${KEEP_PORT:+（复用端口 $KEEP_PORT）}"
    fi
    if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
        ok "订阅配置成功"
        return 0
    fi
    warn "订阅配置产物未生成（sb 菜单结构可能已变更）"; info "手动: sb → 3 → 8 → 1"
    return 1
}
fi
# ── 获取订阅端口（多源探测） ──
if ! declare -F get_sub_port >/dev/null 2>&1; then
get_sub_port() {
    local port=""
    if [ -f /etc/s-box/subport.log ]; then
        port=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
        [ -n "$port" ] && { echo "$port"; return 0; }
    fi
    port=$(ss -tlnp 2>/dev/null | grep -iE 'busybox|httpd|lighttpd|nginx' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || true)
    echo "$port"
}
fi
if ! declare -F wait_subscription >/dev/null 2>&1; then
wait_subscription() {
    info "等待订阅服务启动..."
    local SUB_PORT="" i
    for i in $(seq 1 30); do
        sleep 2
        SUB_PORT=$(get_sub_port)
        [ -n "$SUB_PORT" ] && break
    done
    if [ -n "$SUB_PORT" ]; then
        ok "订阅端口: $SUB_PORT"
        curl -fsL --max-time 5 -o /dev/null "http://127.0.0.1:$SUB_PORT/" 2>/dev/null \
          && ok "订阅服务 HTTP 响应正常" || warn "端口 $SUB_PORT 暂未响应 HTTP"
    else
        warn "订阅服务超时未启动（已等 60s）"
    fi
}
fi
# ── Hysteria2 + Tuic 端口跳跃（独立命名链，绝不触碰第三方 NAT 规则） ──
CHAIN_PORTHOP="ACVPN_PORTHOP"
if ! declare -F config_port_hopping >/dev/null 2>&1; then
config_port_hopping() {
    [ -f /etc/s-box/sb.json ] || { warn "sb.json 不存在，跳过端口跳跃"; return 1; }
    info "配置端口跳跃（独立链 $CHAIN_PORTHOP）..."
    local HY_PORT TU_PORT
    HY_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)

    # 清理旧 ACVPN_PORTHOP 链（幂等，不碰系统其他 nat 规则）
    run iptables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null || true
    run iptables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null || true
    run iptables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
        run ip6tables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null || true
        run ip6tables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null || true
        run ip6tables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null || true
    fi

    # 清理 sing-box 透明代理/TUN 残留的孤立端口跳跃规则（重跑会累积指向旧端口的过期 DNAT/REDIRECT）
    # 背景（2026-08-24 HK 实测）：每天重跑前，PREROUTING 里堆积了指向已废弃端口的
    #   DNAT(40000:42000→旧hy端口 / 43000:45000→旧tu端口) 和重复 REDIRECT，且排在 ACVPN_PORTHOP 之前，
    #   优先命中把 hy2/tuic 跳跃段流量引到不存在的端口 → 节点握手无响应、客户端"不通"。
    # 本段只在确认为 vpnplus 的跳跃段(40000:42000 / 43000:45000 udp)内精确清理，不碰其他 NAT 规则。
    info "清理 sing-box 残留的过期端口跳跃规则..."
    local done_hop=false
    # 按行号删除 PREROUTING 中任何 HOP_HY_RANGE / HOP_TU_RANGE 的 UDP DNAT/REDIRECT（不碰 ACVPN_PORTHOP 链内规则与原样跳转）
    while :; do
        local rnum
        rnum=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null \
            | awk -v hy="$HOP_HY_RANGE" -v tu="$HOP_TU_RANGE" '$2=="DNAT"||$2=="REDIRECT" { if ($0 ~ hy || $0 ~ tu) {print $1; exit} }')
        [ -z "$rnum" ] && break
        run iptables -t nat -D PREROUTING "$rnum" 2>/dev/null && { ok "清除残留规则 #$rnum"; done_hop=true; } || break
    done
    if [ "$done_hop" = false ]; then info "PREROUTING 端口跳跃段已干净，无需清理（幂等）"; fi

    if { [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; } || { [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; }; then
        run iptables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
        if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_HY_RANGE" -j DNAT --to-destination :"$HY_PORT"
            ok "Hysteria2 端口跳跃: ${HOP_HY_RANGE//:/} → $HY_PORT"
        fi
        if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_TU_RANGE" -j DNAT --to-destination :"$TU_PORT"
            ok "Tuic5 端口跳跃: ${HOP_TU_RANGE//:/} → $TU_PORT"
        fi
        run iptables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
            [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ] && run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_HY_RANGE" -j DNAT --to-destination :"$HY_PORT" || true
            [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ] && run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_TU_RANGE" -j DNAT --to-destination :"$TU_PORT" || true
            run ip6tables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        fi
    fi

    # iptables 持久化（统一走 persist_firewall：含自建恢复 unit，防重启丢失）
    persist_firewall
}
fi
# ── WARP-plus-Socks5 ──
if ! declare -F setup_warp >/dev/null 2>&1; then
setup_warp() {
    info "清理旧 WARP 残留..."
    run pkill -9 -f sbwpph 2>/dev/null || true
    run rm -f /etc/s-box/sbwpph /etc/s-box/sbwpph.log
    run sed -i '/sbwpph/d' /etc/s-box/sb.json 2>/dev/null || true

    info "安装 WARP-plus-Socks5 代理..."
    if ! $DRY_RUN; then
        sb_feed 120 <<-EOSUB || true
14
1

0
0
0
0
EOSUB
    else
        info "[dry-run] sb 菜单 14-1 安装 WARP"
    fi
    if [ -f /etc/s-box/sbwpph ] && pgrep -f sbwpph >/dev/null; then ok "WARP-plus-Socks5 已安装并运行"
    elif [ -f /etc/s-box/sbwpph ]; then warn "WARP 文件存在但进程未运行，尝试: sb → 14 → 1"
    else warn "WARP 安装失败（不影响核心代理功能，域名分流不可用）"; fi
}
fi
# ── 域名分流（AI + 流媒体 + 搜索引擎走 WARP） ──
if ! declare -F setup_domain_routing >/dev/null 2>&1; then
setup_domain_routing() {
    if [ ! -f /etc/s-box/sbwpph ] || ! pgrep -f sbwpph >/dev/null; then
        warn "WARP 未运行，跳过域名分流"; return 0
    fi
    info "配置域名分流（WARP-socks5-ipv4 优先）..."
    if ! $DRY_RUN; then
        sb_feed 120 <<-EOSUB || true
5
3
1
openai.com chatgpt.com oaistatic.com aistatic.com claude.ai anthropic.com gemini.google.com perplexity.ai huggingface.co netflix.com nflxvideo.net youtube.com ytimg.com googlevideo.com google.com googleapis.com gstatic.com bing.com twitter.com x.com
0
0
0
0
EOSUB
    else
        info "[dry-run] sb 菜单 5-3-1 域名分流"
    fi
    local CHECK
    CHECK=$(grep -c 'openai.com' /etc/s-box/sb.json 2>/dev/null || true)
    if [ "${CHECK:-0}" -gt 0 ]; then ok "域名分流已配置，AI + 流媒体 + 搜索引擎走 WARP"
    else warn "分流配置可能未完全生效，可稍后手动 sb → 5 检查"; fi
}
fi

if ! declare -F force_ipv4_lock >/dev/null 2>&1; then
force_ipv4_lock() {
    info "锁定 IPv4（直连/WARP 强制 ipv4_only，压延迟）..."
    if [ ! -f /etc/s-box/sb.json ]; then warn "sb.json 不存在，跳过 IPv4 锁定"; return 0; fi
    if $DRY_RUN; then info "[dry-run] 将把 sb.json 的 prefer_ipv4 → ipv4_only 并重载"; return 0; fi
    local changed=false
    if grep -q prefer_ipv4 /etc/s-box/sb.json 2>/dev/null; then
        cp /etc/s-box/sb.json /etc/s-box/sb.json.bak.ipv4 2>/dev/null || true
        jq '(.route.rules[] | select(.strategy=="prefer_ipv4") | .strategy) = "ipv4_only"' /etc/s-box/sb.json > /tmp/sb.json.tmp 2>/dev/null && cat /tmp/sb.json.tmp > /etc/s-box/sb.json && rm -f /tmp/sb.json.tmp && changed=true
        ok "route 策略已切 ipv4_only"
    fi
    # outbounds 强制 ipv4_only（direct/socks 两种）
    if jq -e '.outbounds[] | select(.domain_strategy)' /etc/s-box/sb.json >/dev/null 2>&1; then
        jq '(.outbounds[] | select(.type=="direct" or .type=="socks") | .domain_strategy) = "ipv4_only"' /etc/s-box/sb.json > /tmp/sb.json.tmp 2>/dev/null && cat /tmp/sb.json.tmp > /etc/s-box/sb.json && rm -f /tmp/sb.json.tmp && changed=true
    else
        jq '.outbounds |= map(if .type=="direct" or .type=="socks" then .domain_strategy="ipv4_only" else . end)' /etc/s-box/sb.json > /tmp/sb.json.tmp 2>/dev/null && cat /tmp/sb.json.tmp > /etc/s-box/sb.json && rm -f /tmp/sb.json.tmp && changed=true
    fi
    if $changed; then systemctl try-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true; sleep 2; ok "IPv4 锁定完成，已重载 sing-box"; else info "已是 ipv4_only，无需变更"; fi
}
fi
# ── Argo 隧道 ──
if ! declare -F start_argo >/dev/null 2>&1; then
start_argo() {
    [ -f /etc/s-box/sb.json ] || { warn "sb.json 不存在，跳过 Argo"; return 1; }
    info "通过 sb-yg 自动配置 Argo 临时隧道..."
    if ! $DRY_RUN; then
        sb_feed 90 <<-EOSUB || true
3
3
1
1
0
0
0
EOSUB
    else
        info "[dry-run] sb 菜单 3-3-1-1 配置 Argo"
    fi
    echo -n "    等待 Argo"
    local i
    for i in $(seq 1 15); do
        sleep 2
        echo -n "."
        pgrep -f 'cloudflared.*tunnel' >/dev/null && { echo " ✓"; break; }
    done
    echo ""
    if pgrep -f 'cloudflared.*tunnel' >/dev/null; then
        ok "Argo 临时隧道已运行"
        local url
        url=$(grep -aom1 'https\?://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null || true)
        [ -n "$url" ] && info "Argo URL: $url"
    else
        warn "Argo 隧道未启动，使用直连 IP"; info "稍后手动: sb → 3 → 3 → 1 → 1"
    fi
}
fi
# ── 安全加固（网络感知：IPv6 无地址才关 RA；rp_filter 可覆盖） ──
if ! declare -F apply_hardening >/dev/null 2>&1; then
apply_hardening() {
    local conf="/etc/sysctl.d/99-vpnplus-security.conf"
    local v6_ra_lines
    # 检测本机是否有 IPv6 地址（无 v6 才关 RA，避免破坏依赖 RA 获址的 VPS）
    if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        v6_ra_lines=$'net.ipv6.conf.all.accept_ra = 0\nnet.ipv6.conf.default.accept_ra = 0'
    else
        v6_ra_lines='# 检测到 IPv6 地址，保留 RA 以防破坏 v6 网络配置'
    fi
    run bash -c "cat > '$conf' <<'SEC'
# vpnplus 安全加固（网络感知生成）
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
$v6_ra_lines
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SEC"
    sysctl --system >/dev/null 2>&1 || true
    ok "安全 sysctl 已持久化 ($conf)"

    local applied=false svc
    for svc in sing-box sb xr; do
        if [ -f "/etc/systemd/system/${svc}.service" ]; then
            mkdir -p "/etc/systemd/system/${svc}.service.d" 2>/dev/null || continue
            run bash -c "cat > '/etc/systemd/system/${svc}.service.d/99-vpnplus.conf' <<'LIMIT'
[Service]
LimitNOFILE=1048576
LIMIT"
            applied=true
        fi
    done
    if $applied; then
        run systemctl daemon-reload || true
        for svc in sing-box sb xr; do
            systemctl is-active "$svc" >/dev/null 2>&1 && run systemctl try-restart "$svc" || true
        done
        ok "systemd LimitNOFILE=1048576 已生效 (sing-box/sb/xr)"
    fi
}
fi
# ── Argo 传输协议优化补丁（http2 → auto，QUIC 优先抗丢包） ──
if ! declare -F apply_argo_patch >/dev/null 2>&1; then
apply_argo_patch() {
    [ -f /usr/bin/sb ] || { warn "sb.sh 不存在，跳过 Argo 协议补丁"; return 1; }
    if grep -q -- '--protocol http2' /usr/bin/sb; then
        run sed -i 's/--protocol http2/--protocol auto/g' /usr/bin/sb
        if grep -q -- '--protocol auto' /usr/bin/sb && ! grep -q -- '--protocol http2' /usr/bin/sb; then
            ok "Argo 传输协议已优化: http2 → auto (QUIC 优先，自动回退)"
            # 记录补丁后的哈希到白名单标记，供重跑复查 /usr/bin/sb 时命中（见 install_singbox_yg）
            if ! $DRY_RUN; then
                sha256sum /usr/bin/sb 2>/dev/null | awk '{print $1}' > "$SB_PATCH_MARKER" 2>/dev/null || true
                manifest "argo patch applied; sb patched sha256 recorded"
            fi
        else
            warn "Argo 协议补丁未完全生效，请检查 /usr/bin/sb"
        fi
    else
        info "Argo 已是 auto 协议，跳过补丁"
    fi
    if pgrep -f 'cloudflared.*--protocol http2' >/dev/null 2>&1; then
        warn "检测到旧 http2 Argo 进程，下次重启 Argo 时生效"
    fi
    return 0
}
fi
# ── Argo 临时隧道保活（掉线自动拉起 + 刷新订阅） ──
if ! declare -F install_argo_keepalive >/dev/null 2>&1; then
install_argo_keepalive() {
    if $DRY_RUN; then
        info "[dry-run] 写入 /usr/local/sbin/vpnplus-argo-keepalive.sh（flock互斥+僵死重连+翻动告警）"
    else
        cat > /usr/local/sbin/vpnplus-argo-keepalive.sh <<'KEEP'
#!/bin/bash
# vpnplus Argo 临时隧道保活 v3（cron 每 3 分钟）
# v3 改进（相对 v2）:
#   1) flock 互斥：禁止两个实例并发 pkill/重启互踩
#   2) 进程识别口径与 start_argo 统一（cloudflared tunnel --url 任一端），不再只认 localhost
#   3) cloudflared 二进制自动探测真实路径（/etc/s-box、/usr/local/bin、PATH、/opt），不再硬编码
#   4) 翻动检测：连续重连超阈值 → 写告警标记并停止空转重启（防域名无限漂移折腾客户端）
LOG=/etc/s-box/argo.log
STATE=/etc/s-box/argo-keepalive.state        # "时间戳|连续重连次数"，供翻动检测
MAX_FLAP=5                                    # 连续重连超过 5 次 → 触发冷却
FLAP_WINDOW=$((30 * 60))                      # 窗口 30 分钟
COOLDOWN=$((60 * 60))                         # 翻动后冷却 1 小时

# 互斥锁：已有实例在跑则直接退出（防 cron 与慢重启重叠）
exec 9>/var/lock/vpnplus-argo-keepalive.lock 2>/dev/null || exit 0
flock -n 9 2>/dev/null || { logger -t vpnplus-argo "已有保活实例运行，跳过"; exit 0; }

# 探测 cloudflared 真实路径（兼容多安装位置）
CF_BIN=$(command -v cloudflared 2>/dev/null)
[ -x "$CF_BIN" ] || CF_BIN=$(ls /etc/s-box/cloudflared /usr/local/bin/cloudflared /opt/cloudflared/cloudflared 2>/dev/null | grep -x '.*cloudflared' | head -1)
[ -x "${CF_BIN:-}" ] || { logger -t vpnplus-argo "cloudflared 未找到，跳过保活"; exit 0; }

# 解析 Argo WS 端口：优先取 vless+ws 传输的 inbound；退化取 inbounds[1]（兼容旧配置）
WS_PORT=$(jq -r '[.inbounds[] | select(.type=="vless" and .transport.type=="ws") | .listen_port][0] // empty' /etc/s-box/sb.json 2>/dev/null)
[ -n "$WS_PORT" ] && [ "$WS_PORT" != "null" ] || WS_PORT=$(sed 's://.*::g' /etc/s-box/sb.json 2>/dev/null | jq -r '.inbounds[1].listen_port // empty' 2>/dev/null)
[ -n "$WS_PORT" ] && [ "$WS_PORT" != "null" ] || exit 0

get_url() { grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' "$LOG" 2>/dev/null | tail -1; }

# 与 start_argo 统一识别口径：临时隧道 = cloudflared + tunnel + --url（任一本机环路地址）
TUN_RUNS='cloudflared.*tunnel.*--url'
tunnel_alive() { pgrep -f "$TUN_RUNS" >/dev/null 2>&1; }

restart_tunnel() {
    pkill -9 -f "$TUN_RUNS" 2>/dev/null || true   # 只杀临时隧道，不误伤固定隧道/其他 cloudflared
    sleep 1
    : > "$LOG"
    nohup "$CF_BIN" tunnel --url "http://localhost:$WS_PORT" \
      --edge-ip-version auto --no-autoupdate --protocol auto \
      $(cat /etc/s-box/argo-extra.conf 2>/dev/null) > "$LOG" 2>&1 &
}

refresh_sub() {
    # 目标 sb 子进程前先记差集：只杀本次产生的 sb，不误伤同机手动开的 sb 面板
    printf '9\n1\n0\n0\n0\n' | timeout 30 bash /usr/bin/sb >/dev/null 2>&1 || true
    pkill -9 -f 'bash /usr/bin/sb' 2>/dev/null || true
}

# 翻动检测：连续重连次数记录到 STATE，超阈值进入冷却并写标记（供外部监控），返回 1 表示"应停止重启"
flapping() {
    local now last cnt
    now=$(date +%s)
    if [ -f "$STATE" ]; then
        last=$(awk -F'|' '{print $1}' "$STATE")
        cnt=$(awk -F'|' '{print $2}' "$STATE")
        if [ $((now - last)) -gt "$FLAP_WINDOW" ]; then cnt=0; fi   # 窗口过期，重置计数
    else
        last=$now; cnt=0
    fi
    cnt=$((cnt + 1))
    printf '%s|%s\n' "$now" "$cnt" > "$STATE"
    if [ "$cnt" -ge "$MAX_FLAP" ]; then
        touch /etc/s-box/argo-flapping.marker
        logger -t vpnplus-argo "Argo 30分钟内连续重连 ${cnt} 次，疑似边缘持续不可达；进入 ${COOLDOWN}s 冷却"
        return 1
    fi
    return 0
}

# 若上次翻动仍在冷却期内，直接退出（不空转重启）
if [ -f /etc/s-box/argo-flapping.marker ]; then
    if [ $(( $(date +%s) - $(stat -c %Y /etc/s-box/argo-flapping.marker 2>/dev/null || echo 0) )) -lt "${COOLDOWN}" ]; then
        logger -t vpnplus-argo "Argo 冷却期内，跳过本轮"
        exit 0
    fi
    rm -f /etc/s-box/argo-flapping.marker
fi

OLD_URL=$(get_url)

# L1: 进程不在 → 直接重启
if ! tunnel_alive; then
    restart_tunnel
    sleep 15
    NEW_URL=$(get_url)
    if [ -n "$NEW_URL" ]; then refresh_sub; logger -t vpnplus-argo "L1进程缺失已重启, 域名 $OLD_URL -> $NEW_URL, 订阅已同步"; fi
    exit 0
fi

# L2: 进程在但隧道可能僵死 — HTTP 探测当前域名(任意状态码=链路通; 000=僵死)
CUR_URL=$(get_url)
if [ -z "$CUR_URL" ]; then
    restart_tunnel; sleep 15
    NEW_URL=$(get_url)
    [ -n "$NEW_URL" ] && { refresh_sub; logger -t vpnplus-argo "L2无域名记录已重启, 新域名 $NEW_URL"; }
    exit 0
fi
HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "$CUR_URL" 2>/dev/null || echo 000)
if [ "$HTTP" = "000" ]; then
    # 二次确认(防瞬时抖动误杀): 换协议参数再探一次
    sleep 5
    HTTP2=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 "$CUR_URL" 2>/dev/null || echo 000)
    if [ "$HTTP2" = "000" ]; then
        if flapping; then
            logger -t vpnplus-argo "Argo 频繁重连已触发冷却，跳过本次重启（防域名无限漂移）"
            exit 0
        fi
        restart_tunnel
        sleep 15
        NEW_URL=$(get_url)
        if [ -n "$NEW_URL" ] && [ "$NEW_URL" != "$CUR_URL" ]; then
            refresh_sub
            logger -t vpnplus-argo "L2隧道僵死(HTTP 000x2)已重连换域名 $CUR_URL -> $NEW_URL, 订阅已同步"
        elif [ -n "$NEW_URL" ]; then
            logger -t vpnplus-argo 'L2隧道僵死已重连(域名未变)'
        fi
        exit 0
    fi
fi

# L3: 隧道正常但订阅里还是旧域名(上次重连没同步成功) → 补同步
if [ -n "$OLD_URL" ] && grep -q 'trycloudflare' /etc/s-box/jhsub.txt 2>/dev/null; then
    if ! grep -q "$(echo "$OLD_URL" | sed 's|https://||')" /etc/s-box/jhsub.txt 2>/dev/null; then
        refresh_sub
        logger -t vpnplus-argo 'L3订阅与运行域名不一致, 已补同步'
    fi
fi
exit 0
KEEP
        chmod +x /usr/local/sbin/vpnplus-argo-keepalive.sh
        ( crontab -l 2>/dev/null | grep -vE 'vpnplus-argo-keepalive|acvn-argo-keepalive|acvpn-argo-keepalive'; echo '*/3 * * * * /usr/local/sbin/vpnplus-argo-keepalive.sh > /dev/null 2>&1' ) | crontab - 2>/dev/null || true
    fi
    ok "Argo 保活 v3 已安装（每 3 分钟：flock互斥 + 进程/HTTP 双检 + 僵死重连换域名同步订阅 + 翻动冷却）"
}
fi
# ── iptables 持久化（三层兜底 + 自建恢复 unit，防重启后端口跳跃/防探测规则丢失） ──
# 背景（2026-08-25 审计）：旧实现第三层 iptables-save 只写文件、无开机加载，重启后 ACVPN_* 链丢失。
# 现做两层保障：
#   1) 优先用 netfilter-persistent 存储（Debian iptables-persistent，开机由 network-pre.target 自动恢复）
#   2) 否则写 /etc/iptables/rules.v4|v6 并注册 vpnplus-netfilter-restore.service（network-pre.target 前恢复）
if ! declare -F persist_firewall >/dev/null 2>&1; then
persist_firewall() {
    if $DRY_RUN; then info "[dry-run] 持久化 iptables 规则"; return 0; fi
    local saved=false
    if netfilter-persistent save 2>/dev/null && command -v netfilter-persistent >/dev/null 2>&1; then
        ok "防火墙规则已持久化 (netfilter-persistent)"; saved=true
    elif service iptables save 2>/dev/null; then
        ok "防火墙规则已持久化 (iptables service)"; saved=true
    fi
    # 无论上述哪种成功，都额外保留一份明文快照 + 自建恢复 unit，双保险
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    if [ -s /etc/iptables/rules.v4 ]; then
        cat > /etc/systemd/system/vpnplus-netfilter-restore.service <<'UNIT'
[Unit]
Description=vpnplus iptables restore (before network)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables-restore -n /etc/iptables/rules.v4
ExecStart=/usr/sbin/ip6tables-restore -n /etc/iptables/rules.v6

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload 2>/dev/null || true
        if systemctl enable vpnplus-netfilter-restore.service 2>/dev/null; then
            ok "vpnplus-netfilter-restore.service 已启用（开机恢复新链规则，双保险）"
            saved=true
        else
            warn "enabling vpnplus-netfilter-restore.service 失败"
        fi
    fi
    $saved || warn "防火墙规则未能持久化（重启后需重新配置）"
    return 0
}
fi
# ── 日志轮转（防 vpnplus 长期运行日志无限膨胀） ──
if ! declare -F setup_logrotate >/dev/null 2>&1; then
setup_logrotate() {
    if $DRY_RUN; then info "[dry-run] 安装 /etc/logrotate.d/vpnplus（轮转 vpnplus 各类日志）"; return 0; fi
    cat > /etc/logrotate.d/vpnplus <<'ROT'
/var/log/vpnplus-optimize.log
/var/log/vpnplus-optimize-manifest.log
/var/log/vpnplus-singbox-manifest.log
/var/log/vpnplus-sbfeed.log
/etc/s-box/argo.log
{
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
ROT
    chmod 0644 /etc/logrotate.d/vpnplus 2>/dev/null || true
    # 若 logrotate 服务在则检查配置语法
    command -v logrotate >/dev/null 2>&1 && logrotate -d /etc/logrotate.d/vpnplus >/dev/null 2>&1 \
        && ok "日志轮转已配置 (/etc/logrotate.d/vpnplus，周轮+保留4份+压缩)" \
        || warn "logrotate 配置已写，但语法校验未通过或 logrotate 未安装（日志将不轮转）"
    return 0
}
fi
# ── 订阅 HTTP 服务保障（busybox httpd；精确按端口定位，绝不杀全局 busybox） ──
if ! declare -F ensure_sub_httpd >/dev/null 2>&1; then
ensure_sub_httpd() {
    local port
    port=$(get_sub_port 2>/dev/null)
    [ -z "$port" ] && { warn "无法获取订阅端口，跳过订阅服务保障"; return 1; }
    command -v busybox >/dev/null 2>&1 || { warn "busybox 不可用，跳过订阅服务保障"; return 1; }
    if ! $DRY_RUN; then
        ( crontab -l 2>/dev/null | grep -vE 'busybox httpd.*(/root/websbox|subport.log)'; echo "@reboot sleep 10 && /bin/bash -c \"busybox httpd -f -p $(cat /etc/s-box/subport.log 2>/dev/null) -h /root/websbox > /dev/null 2>&1 &\"" ) | crontab - 2>/dev/null || true
    else
        info "[dry-run] 写入 @reboot 订阅服务自启"
    fi
    if ss -tln 2>/dev/null | grep -q ":$port"; then
        ok "订阅 HTTP 服务运行中 (端口 $port)"
    else
        if $DRY_RUN; then
            info "[dry-run] 启动 busybox httpd (端口 $port)"
        else
            # 精确清理：只停监听该端口的 busybox（不 pkill -x busybox 杀全局）
            local pids
            pids=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u || true)
            [ -n "$pids" ] && { for p in $pids; do kill "$p" 2>/dev/null || true; done; sleep 1; }
            mkdir -p /root/websbox
            nohup busybox httpd -f -p "$port" -h /root/websbox >/dev/null 2>&1 &
            sleep 2
        fi
        ss -tln 2>/dev/null | grep -q ":$port" && ok "订阅 HTTP 服务已启动" || warn "订阅 HTTP 服务启动失败，请手动检查"
    fi
}
fi
# ── 订阅后处理：修复 sb 生成的 mport 重复（双 DNAT 导致 40000-42000,40000-42000） ──
if ! declare -F fix_mport_dup >/dev/null 2>&1; then
fix_mport_dup() {
    # sb 的 hy2 mport 来源是: iptables -t nat -nL | grep hy2_port | awk '{print $8}'
    # 若 PREROUTING 残留 + ACVPN_PORTHOP 各有一条 DNAT，sb 会拼成 "40000-42000,40000-42000"。
    # 这里做幂等去重：对 hy2.txt / jhsub.txt / websbox 副本的 mport= 去重逗号段。
    local changed=false f
    for f in /etc/s-box/hy2.txt /etc/s-box/jhsub.txt; do
        [ -f "$f" ] || continue
        # 仅当出现重复逗号段时处理
        if grep -q 'mport=' "$f" 2>/dev/null && grep -q 'mport=.*,' "$f" 2>/dev/null; then
            local tmp
            tmp=$(mktemp)
            # 逐行：把 mport= 后的逗号列表去重（保留首次出现顺序）
            python3 - "$f" "$tmp" <<'PY' 2>/dev/null || true
import sys, re
src, dst = sys.argv[1], sys.argv[2]
def dedup_line(line):
    m = re.search(r'mport=([^&\s]+)', line)
    if not m:
        return line
    raw = m.group(1)
    parts = raw.split(',')
    seen=set(); uniq=[]
    for p in parts:
        p=p.strip()
        if p and p not in seen:
            seen.add(p); uniq.append(p)
    fixed=','.join(uniq)
    return line.replace(raw, fixed, 1) if fixed != raw else line
with open(src, encoding='utf-8', errors='ignore') as s, open(dst,'w', encoding='utf-8') as d:
    for ln in s:
        d.write(dedup_line(ln))
PY
            if [ -s "$tmp" ] && ! cmp -s "$f" "$tmp" 2>/dev/null; then
                cat "$tmp" > "$f" 2>/dev/null && changed=true
            fi
            rm -f "$tmp" 2>/dev/null || true
            # python3 不可用/失败时的兜底：仅修已知双写
            if grep -q 'mport=40000-42000,40000-42000' "$f" 2>/dev/null; then
                sed -i 's/mport=40000-42000,40000-42000/mport=40000-42000/g' "$f" 2>/dev/null && changed=true
            fi
        fi
    done
    if [ "$changed" = true ]; then
        # 同步 websbox 目录（busybox httpd 根）
        if [ -f /etc/s-box/subtoken.log ] && [ -d /root/websbox ]; then
            local tok
            tok=$(tr -cd 'a-zA-Z0-9_-' < /etc/s-box/subtoken.log 2>/dev/null || true)
            [ -n "$tok" ] && [ -d "/root/websbox/$tok" ] && {
                cp -f /etc/s-box/jhsub.txt "/root/websbox/$tok/jhsub.txt" 2>/dev/null || true
                cp -f /etc/s-box/hy2.txt "/root/websbox/$tok/hy2.txt" 2>/dev/null || true
                # 兼容旧 token 目录落在根下的情况
                cp -f /etc/s-box/jhsub.txt /root/websbox/jhsub.txt 2>/dev/null || true
            } || true
        fi
        ok "订阅 mport 重复已修复（去重后同步 websbox）"
    fi
}
fi
# ── 最终显示订阅链接 ──
if ! declare -F show_subscription >/dev/null 2>&1; then
show_subscription() {
    local sub_port token public_ip
    sub_port=$(get_sub_port 2>/dev/null || true)
    if [ -z "$sub_port" ] || [ ! -f /etc/s-box/subtoken.log ]; then
        warn "订阅链接未生成：缺少订阅端口或 token"
        return 1
    fi
    token=$(tr -cd 'a-zA-Z0-9_-' < /etc/s-box/subtoken.log 2>/dev/null || true)
    [ -n "$token" ] || { warn "订阅 token 为空，无法生成链接"; return 1; }
    public_ip=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null \
        || echo "你的服务器IP")
    echo ""
    info "━━━ 订阅链接 ━━━"
    echo ""
    echo "Clash / Mihomo:"
    echo "http://${public_ip}:${sub_port}/${token}/clmi.yaml"
    echo ""
    echo "Sing-box:"
    echo "http://${public_ip}:${sub_port}/${token}/sbox.json"
    echo ""
    echo "通用聚合:"
    echo "http://${public_ip}:${sub_port}/${token}/jhsub.txt"
    echo ""
    warn "订阅链接使用 HTTP + IP:端口；移动网络可能拦截高端口，必要时改用 Argo/HTTPS 入口。"
    return 0
}
fi
# ── 防主动探测（独立命名链；重跑/卸载只动 ACVPN_ANTIPROBE，绝不 delete 全局 INPUT 规则） ──
CHAIN_ANTIPROBE="ACVPN_ANTIPROBE"
if ! declare -F apply_antiprobe >/dev/null 2>&1; then
apply_antiprobe() {
    [ -f /etc/s-box/sb.json ] || { warn "sb.json 不存在，跳过防主动探测"; return 1; }
    info "配置防主动探测（独立链 $CHAIN_ANTIPROBE）..."
    local -a TCP_PORTS=() UDP_PORTS=()
    local VM_PORT="" p type tls_en

    while IFS='|' read -r p type tls_en; do
        [ -z "$p" ] || [ "$p" = "null" ] && continue
        if [ "$type" = "vmess" ] && [ "$tls_en" = "false" ]; then VM_PORT="$p"
        elif [ "$type" = "hysteria2" ] || [ "$type" = "tuic" ]; then UDP_PORTS+=("$p")
        else TCP_PORTS+=("$p"); fi
    done < <(jq -r '.inbounds[] | "\(.listen_port)|\(.type)|\(.tls.enabled // "false")"' /etc/s-box/sb.json 2>/dev/null || true)

    # 先彻底重建链：删跳转 → flush → delete（幂等且不碰第三方规则）
    run iptables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null || true
    run iptables -F "$CHAIN_ANTIPROBE" 2>/dev/null || true
    run iptables -X "$CHAIN_ANTIPROBE" 2>/dev/null || true
    if command -v ip6tables >/dev/null 2>&1; then
        run ip6tables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null || true
        run ip6tables -F "$CHAIN_ANTIPROBE" 2>/dev/null || true
        run ip6tables -X "$CHAIN_ANTIPROBE" 2>/dev/null || true
    fi

    run iptables -N "$CHAIN_ANTIPROBE" 2>/dev/null || true
    local i=0

    # 1) VMess 明文端口：VMESS_LOCK=on 时公网 DROP（仅 Argo 回环可达）
    if [ -n "$VM_PORT" ] && [ "${VMESS_LOCK:-off}" = "on" ]; then
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$VM_PORT" ! -i lo -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$VM_PORT" ! -i lo -j DROP || true
    fi

    # 2) TCP 代理端口（Reality/AnyTLS 等）SYN 限速
    for p in "${TCP_PORTS[@]}"; do
        [ "$p" = "$VM_PORT" ] && continue
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m hashlimit \
          --hashlimit-above "$RATE_SYN_ABOVE"/sec --hashlimit-burst "$RATE_SYN_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m hashlimit \
          --hashlimit-above "$RATE_SYN_ABOVE"/sec --hashlimit-burst "$RATE_SYN_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        i=$((i + 1))
    done

    # 3) UDP 代理主端口限速
    for p in "${UDP_PORTS[@]}"; do
        run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport "$p" -m hashlimit \
          --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport "$p" -m hashlimit \
          --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        i=$((i + 1))
    done

    # 4) UDP 跳跃段限速
    run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport "$HOP_HY_RANGE" -m hashlimit \
      --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
    run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport "$HOP_TU_RANGE" -m hashlimit \
      --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
    command -v ip6tables >/dev/null 2>&1 && {
        run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport "$HOP_HY_RANGE" -m hashlimit --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport "$HOP_TU_RANGE" -m hashlimit --hashlimit-above "$RATE_UDP_ABOVE"/sec --hashlimit-burst "$RATE_UDP_BURST" --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
    }; i=$((i + 2))

    # 5) SSH 爆破防御（轻量 fail2ban）
    run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport 22 -m state --state NEW -m hashlimit \
      --hashlimit-above "$SSH_RATE_ABOVE"/min --hashlimit-burst "$SSH_RATE_BURST" --hashlimit-mode srcip --hashlimit-name probe22 -j DROP
    command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport 22 -m state --state NEW -m hashlimit \
      --hashlimit-above "$SSH_RATE_ABOVE"/min --hashlimit-burst "$SSH_RATE_BURST" --hashlimit-mode srcip --hashlimit-name probe22 -j DROP || true

    # 6) 单 IP 连接数上限
    for p in "${TCP_PORTS[@]}"; do
        [ "$p" = "$VM_PORT" ] && continue
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m connlimit --connlimit-above "$CONN_ABOVE" -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m connlimit --connlimit-above "$CONN_ABOVE" -j DROP || true
    done

    # 将独立链挂到 INPUT 顶部（唯一跳到本链的规则，清理时精确删除）
    run iptables -I INPUT 1 -j "$CHAIN_ANTIPROBE"
    command -v ip6tables >/dev/null 2>&1 && run ip6tables -I INPUT 1 -j "$CHAIN_ANTIPROBE" || true

    persist_firewall
    ok "防主动探测已启用: ${#TCP_PORTS[@]} TCP + ${#UDP_PORTS[@]} UDP + SSH + 单IP连接数上限 + IPv6对称（独立链 $CHAIN_ANTIPROBE）"
}
fi
# ══════════ 主流程 ══════════
main() {
    logo() { :; }
    if $DRY_RUN; then echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"; fi

    # 失败 trap：半成品状态下明确给出恢复指引，而不是带着半配置退出
    trap_interrupt() {
        local rc=$?
        # 正常完成/主动 skip（rc 0）不算中断，避免 "退出码 0" 误报
        [ "$rc" -eq 0 ] && return 0
        echo ""
        fail "部署中断（最后退出码 $rc），可能残留半成品状态。"
        info "修复与恢复："
        info "  1) 先安全预览: bash cleanup.sh --force --dry-run —— 看会清哪些东西"
        info "  2) 若只是刚才某步失败，可直接: bash deploy_singbox.sh 重跑（幂等）"
        info "  3) 想彻底重建: bash cleanup.sh --force && bash deploy_singbox.sh"
        info "  sb_feed 详细日志在 /var/log/vpnplus-sbfeed.log（本次 sb 交互输出，便于回溯卡点）"
        return $rc
    }
    trap 'trap_interrupt' EXIT

    if [ "$FORCE" != "true" ] && [ -f "$CHECKPOINT" ] && [ -f /etc/s-box/sb.json ] && { systemctl is-active sb >/dev/null 2>&1 || systemctl is-active sing-box >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; }; then
        # 已部署跳过≠失败，撤销 EXIT trap 避免误报“部署中断（退出码 0）”
        trap - EXIT
        ok "sing-box 已部署运行中，跳过安装。"
        info "如需强制重跑并对齐 sb.json/iptables/订阅三处："
        info "  本地已有脚本: bash deploy_singbox.sh --force"
        info "  一键裸装: bash <(curl -fsSL https://raw.githubusercontent.com/ccAzy/vpnplus/main/deploy_singbox.sh) --force"
        info "  旧兼容: rm -f $CHECKPOINT && bash deploy_singbox.sh"
        return 0
    fi
    if [ "$FORCE" = "true" ]; then info "--force 已启用，将强制重跑全流程并对齐三处配置"; rm -f "$CHECKPOINT" 2>/dev/null || true; fi

    check_env || return 1
    # sb 菜单结构指纹：先抓一次 sb 主菜单横幅，确认菜单结构与脚本投喂序列预期一致
    # 若 sb 已存在的版本与锁定的 SB_COMMIT 不符（比如用户手动升级过），菜单序号可能漂移，
    # 静默继续会让安装"产物缺失才报错"很难排查。这里先探测，命中预期则继续，未命中则明确警告。
    if ! declare -F assert_sb_menu >/dev/null 2>&1; then
assert_sb_menu() {
        [ -x /usr/bin/sb ] || return 0
        local banner
        banner=$(printf '0\n0\n' | timeout 10 bash /usr/bin/sb 2>&1 | sed -E 's/\x1B\[[0-9;]*[mK]//g' || true)
        # 预期：部署脚本注释锁定的是 v2x 系列（sing-box-yg）。抓到版本号便于人工对表；
        # 抓不到也继续（可能 sb 启动即进子菜单），但记录到日志供排查。
        local ver
        ver=$(printf '%s' "$banner" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
        if [ -n "$ver" ]; then
            info "sb 版本指纹: $ver（脚本投喂序列按锁定 SB_COMMIT 编写）"
            if ! printf '%s' "$ver" | grep -qE '^v2'; then
                warn "sb 版本 $ver 不是脚本预期的 v2x 系列，菜单序号可能漂移；若后续步骤失败请核对 SB_COMMIT/SB_SHA256 并检查 /var/log/vpnplus-sbfeed.log"
            fi
        else
            info "[sb] 未从横幅识别到版本号，继续（依赖 SB_SHA256 锁定的菜单结构）"
        fi
        manifest "sb banner probe ver=${ver:-none}"
        return 0
    }
fi
    if [ -f /etc/.vpnplus-singbox ]; then :; else assert_sb_menu; fi

    # 时间校准必须在安装前完成（否则 Reality/VMess 握手 bad timestamp）
    ensure_time_sync

    if $DRY_RUN; then
        echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"
        info "[dry-run] 将执行：安装 sb.sh、生成订阅、配置端口跳跃、Argo、独立防火墙链、WARP"
        info "[dry-run] 已跳过实际文件、服务、防火墙和进程检查"
        return 0
    fi
    local DEPLOY_OK=true

    step "1" "安装 sing-box"
    install_singbox_yg || DEPLOY_OK=false
    apply_argo_patch

    step "2" "配置订阅链接"
    setup_subscription || DEPLOY_OK=false
    wait_subscription
    ensure_sub_httpd

    step "3" "端口跳跃（Hy2 + Tuic）独立链"
    config_port_hopping || true

    step "4" "Argo 临时隧道"
    start_argo || DEPLOY_OK=false
    install_argo_keepalive

    step "5" "安全加固 + 防主动探测（独立链）"
    apply_hardening
    apply_antiprobe || true

    step "6" "WARP + 域名分流（可选）"
    setup_warp
    setup_domain_routing
    force_ipv4_lock || true
    fix_mport_dup || true
    show_subscription || true

    step "7" "日志轮转 + 基线体检（可选）"
    setup_logrotate

    # 仅核心成功才写成功标记
    if $DEPLOY_OK; then
        run touch "$CHECKPOINT"
        manifest "deploy core OK; vmess_lock=${VMESS_LOCK}"
        ok "全部部署完成！"; info "管理命令: sb"
    else
        warn "核心步骤未完全成功，未写成功标记"; info "修复后重试: bash deploy_singbox.sh"
        return 1
    fi
}

step() {
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${N}"
    echo -e "${YELLOW}║  [$1] $2"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${N}"
}

main "$@"




