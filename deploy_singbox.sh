#!/bin/bash
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
set -uo pipefail

DRY_RUN=false
VMESS_LOCK="${VMESS_LOCK:-on}"     # 安全默认：公网封锁明文 VMess 端口（仅 Argo 回环可达）
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) cat <<'HELP'
vpnplus deploy_singbox.sh — sing-box 一键部署
用法: bash deploy_singbox.sh [--dry-run]
  --dry-run  只打印将执行的动作，不实际修改系统
  VMESS_LOCK=on|off  明文 VMess 端口是否封锁公网（默认 on，仅 Argo 回环可达）
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
        ok "sing-box-yg 管理脚本已就绪"
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
        printf '1\n\n\n\n\n' | timeout 300 sb 2>&1 || { warn "sb 安装菜单执行异常"; }
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

# ── 环境预检 + 第二阶段依赖兜底 ──
check_env() {
    if [ "$(id -u)" -ne 0 ]; then fail "需要 root 权限"; return 1; fi
    if ! command -v apt-get &>/dev/null; then fail "非 Debian/Ubuntu 系统，脚本仅支持 apt 系发行版"; return 1; fi

    # deploy_singbox 也可独立运行：补齐第一阶段可能未执行的工具。
    local packages=(ca-certificates curl jq iproute2 iptables procps psmisc util-linux cron ethtool kmod)
    local missing=() pkg
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        info "缺少第二阶段依赖: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || { fail "apt-get update 失败，检查软件源/网络"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" || { fail "依赖安装失败: ${missing[*]}"; return 1; }
        ok "第二阶段基础依赖安装完成"
    fi
    for cmd in curl jq ip ss iptables systemctl crontab pgrep pkill timeout sha256sum sysctl; do
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
# ── 订阅配置 ──
setup_subscription() {
    info "配置本地订阅链接..."
    sleep 1
    if ! $DRY_RUN; then
        timeout 120 sb 2>&1 <<-EOSUB || { warn "订阅配置菜单执行异常"; return 1; }
3
8
1


0
0
EOSUB
        sleep 3
    else
        info "[dry-run] sb 菜单 3-8-1 配置订阅"
    fi
    if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
        ok "订阅配置成功"; return 0
    fi
    warn "订阅配置产物未生成（sb 菜单结构可能已变更）"; info "手动: sb → 3 → 8 → 1"
    return 1
}

# ── 获取订阅端口（多源探测） ──
get_sub_port() {
    local port=""
    if [ -f /etc/s-box/subport.log ]; then
        port=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
        [ -n "$port" ] && { echo "$port"; return 0; }
    fi
    port=$(ss -tlnp 2>/dev/null | grep -iE 'busybox|httpd|lighttpd|nginx' | awk '{print $4}' | grep -oE '[0-9]+$' | head -1 || true)
    echo "$port"
}

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

# ── Hysteria2 + Tuic 端口跳跃（独立命名链，绝不触碰第三方 NAT 规则） ──
CHAIN_PORTHOP="ACVPN_PORTHOP"
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

    if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ] || [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
        run iptables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
        if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport 40000:42000 -j DNAT --to-destination :"$HY_PORT"
            ok "Hysteria2 端口跳跃: 40000-42000 → $HY_PORT"
        fi
        if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport 43000:45000 -j DNAT --to-destination :"$TU_PORT"
            ok "Tuic5 端口跳跃: 43000-45000 → $TU_PORT"
        fi
        run iptables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
            [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ] && run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport 40000:42000 -j DNAT --to-destination :"$HY_PORT" || true
            [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ] && run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport 43000:45000 -j DNAT --to-destination :"$TU_PORT" || true
            run ip6tables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        fi
    fi

    # iptables 持久化（三层兜底）
    if netfilter-persistent save 2>/dev/null; then ok "规则已持久化 (netfilter-persistent)"
    elif service iptables save 2>/dev/null; then ok "规则已持久化 (iptables service)"
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null || true
        run bash -c "iptables-save > /etc/iptables/rules.v4 2>/dev/null"
        run bash -c "ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true"
        ok "规则已持久化 (iptables-save)"
    else warn "规则未持久化（重启后需重新配置）"; fi
}
# ── WARP-plus-Socks5 ──
setup_warp() {
    info "清理旧 WARP 残留..."
    run pkill -9 -f sbwpph 2>/dev/null || true
    run rm -f /etc/s-box/sbwpph /etc/s-box/sbwpph.log
    run sed -i '/sbwpph/d' /etc/s-box/sb.json 2>/dev/null || true

    info "安装 WARP-plus-Socks5 代理..."
    if ! $DRY_RUN; then
        timeout 120 sb 2>&1 <<-EOSUB || true
14
1

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

# ── 域名分流（AI + 流媒体 + 搜索引擎走 WARP） ──
setup_domain_routing() {
    if [ ! -f /etc/s-box/sbwpph ] || ! pgrep -f sbwpph >/dev/null; then
        warn "WARP 未运行，跳过域名分流"; return 0
    fi
    info "配置域名分流（WARP-socks5-ipv4 优先）..."
    if ! $DRY_RUN; then
        timeout 120 sb 2>&1 <<-EOSUB || true
5
3
1
openai.com chatgpt.com oaistatic.com aistatic.com claude.ai anthropic.com gemini.google.com perplexity.ai huggingface.co netflix.com nflxvideo.net youtube.com ytimg.com googlevideo.com google.com googleapis.com gstatic.com bing.com twitter.com x.com
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

# ── Argo 隧道 ──
start_argo() {
    [ -f /etc/s-box/sb.json ] || { warn "sb.json 不存在，跳过 Argo"; return 1; }
    info "通过 sb-yg 自动配置 Argo 临时隧道..."
    if ! $DRY_RUN; then
        timeout 90 sb 2>&1 <<-EOSUB || true
3
3
1
1
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

# ── 安全加固（网络感知：IPv6 无地址才关 RA；rp_filter 可覆盖） ──
apply_hardening() {
    local conf="/etc/sysctl.d/99-vpnplus-security.conf"
    local v6_ra=""
    # 检测本机是否有 IPv6 地址（无 v6 才关 RA，避免破坏依赖 RA 获址的 VPS）
    if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        v6_ra="1"
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
$( [ \"\$v6_ra\" = \"1\" ] && printf 'net.ipv6.conf.all.accept_ra = 0\\nnet.ipv6.conf.default.accept_ra = 0\\n' || printf '# 检测到 IPv6 地址，保留 RA 以防破坏 v6 网络配置\\n' )
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
# ── Argo 传输协议优化补丁（http2 → auto，QUIC 优先抗丢包） ──
apply_argo_patch() {
    [ -f /usr/bin/sb ] || { warn "sb.sh 不存在，跳过 Argo 协议补丁"; return 1; }
    if grep -q -- '--protocol http2' /usr/bin/sb; then
        run sed -i 's/--protocol http2/--protocol auto/g' /usr/bin/sb
        if grep -q -- '--protocol auto' /usr/bin/sb && ! grep -q -- '--protocol http2' /usr/bin/sb; then
            ok "Argo 传输协议已优化: http2 → auto (QUIC 优先，自动回退)"
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

# ── Argo 临时隧道保活（掉线自动拉起 + 刷新订阅） ──
install_argo_keepalive() {
    run bash -c "cat > /usr/local/sbin/vpnplus-argo-keepalive.sh <<'KEEP'
#!/bin/bash
# vpnplus Argo 临时隧道保活（由 cron 每 3 分钟调用）
LOG=/etc/s-box/argo.log
pgrep -f 'cloudflared.*tunnel.*localhost' >/dev/null 2>&1 && exit 0
WS_PORT=\$(sed 's://.*::g' /etc/s-box/sb.json 2>/dev/null | jq -r '.inbounds[1].listen_port' 2>/dev/null)
[ -n \"\$WS_PORT\" ] && [ \"\$WS_PORT\" != \"null\" ] || exit 0
pkill -9 -f 'cloudflared.*tunnel.*localhost' 2>/dev/null || true
sleep 1
nohup /etc/s-box/cloudflared tunnel --url \"http://localhost:\$WS_PORT\" \\
  --edge-ip-version auto --no-autoupdate --protocol auto \\
  \$(cat /etc/s-box/argo-extra.conf 2>/dev/null) > \"\$LOG\" 2>&1 &
sleep 15
if pgrep -f 'cloudflared.*tunnel.*localhost' >/dev/null 2>&1; then
    printf '9\\n1\\n' | bash /usr/bin/sb > /dev/null 2>&1 || true
    logger -t vpnplus-argo '临时隧道掉线后已自动重启并刷新订阅'
fi
exit 0
KEEP"
    run chmod +x /usr/local/sbin/vpnplus-argo-keepalive.sh
    if ! $DRY_RUN; then
        ( crontab -l 2>/dev/null | grep -v 'vpnplus-argo-keepalive' | grep -v 'acvpn-argo-keepalive'; echo '*/3 * * * * /usr/local/sbin/vpnplus-argo-keepalive.sh > /dev/null 2>&1' ) | crontab - 2>/dev/null || true
    else
        info "[dry-run] 写入 cron: vpnplus-argo-keepalive 每3分钟"
    fi
    ok "Argo 保活已安装（每 3 分钟自检，掉线自动拉起并刷新订阅）"
}

# ── 订阅 HTTP 服务保障（busybox httpd；精确按端口定位，绝不杀全局 busybox） ──
ensure_sub_httpd() {
    local port
    port=$(get_sub_port 2>/dev/null)
    [ -z "$port" ] && { warn "无法获取订阅端口，跳过订阅服务保障"; return 1; }
    command -v busybox >/dev/null 2>&1 || { warn "busybox 不可用，跳过订阅服务保障"; return 1; }
    if ! $DRY_RUN; then
        ( crontab -l 2>/dev/null | grep -v 'busybox httpd'; echo "@reboot sleep 10 && /bin/bash -c \"busybox httpd -f -p $(cat /etc/s-box/subport.log 2>/dev/null) -h /root/websbox > /dev/null 2>&1 &\"" ) | crontab - 2>/dev/null || true
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

# ── 防主动探测（独立命名链；重跑/卸载只动 ACVPN_ANTIPROBE，绝不 delete 全局 INPUT 规则） ──
CHAIN_ANTIPROBE="ACVPN_ANTIPROBE"
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
    if [ -n "$VM_PORT" ] && [ "${VMESS_LOCK:-on}" = "on" ]; then
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$VM_PORT" ! -i lo -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$VM_PORT" ! -i lo -j DROP || true
    fi

    # 2) TCP 代理端口（Reality/AnyTLS 等）SYN 限速
    for p in "${TCP_PORTS[@]}"; do
        [ "$p" = "$VM_PORT" ] && continue
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m hashlimit \
          --hashlimit-above 50/sec --hashlimit-burst 100 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m hashlimit \
          --hashlimit-above 50/sec --hashlimit-burst 100 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        i=$((i + 1))
    done

    # 3) UDP 代理主端口限速
    for p in "${UDP_PORTS[@]}"; do
        run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport "$p" -m hashlimit \
          --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport "$p" -m hashlimit \
          --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        i=$((i + 1))
    done

    # 4) UDP 跳跃段限速
    run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport 40000:42000 -m hashlimit \
      --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
    run iptables -A "$CHAIN_ANTIPROBE" -p udp --dport 43000:45000 -m hashlimit \
      --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP
    command -v ip6tables >/dev/null 2>&1 && {
        run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport 40000:42000 -m hashlimit --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
        run ip6tables -A "$CHAIN_ANTIPROBE" -p udp --dport 43000:45000 -m hashlimit --hashlimit-above 200/sec --hashlimit-burst 400 --hashlimit-mode srcip --hashlimit-name "probe$i" -j DROP || true
    }; i=$((i + 2))

    # 5) SSH 爆破防御（轻量 fail2ban）
    run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport 22 -m state --state NEW -m hashlimit \
      --hashlimit-above 3/min --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-name probe22 -j DROP
    command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport 22 -m state --state NEW -m hashlimit \
      --hashlimit-above 3/min --hashlimit-burst 5 --hashlimit-mode srcip --hashlimit-name probe22 -j DROP || true

    # 6) 单 IP 连接数上限
    for p in "${TCP_PORTS[@]}"; do
        [ "$p" = "$VM_PORT" ] && continue
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m connlimit --connlimit-above 200 -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$p" -m state --state NEW -m connlimit --connlimit-above 200 -j DROP || true
    done

    # 将独立链挂到 INPUT 顶部（唯一跳到本链的规则，清理时精确删除）
    run iptables -I INPUT 1 -j "$CHAIN_ANTIPROBE"
    command -v ip6tables >/dev/null 2>&1 && run ip6tables -I INPUT 1 -j "$CHAIN_ANTIPROBE" || true

    if netfilter-persistent save 2>/dev/null; then ok "防探测规则已持久化 (netfilter-persistent)"
    elif service iptables save 2>/dev/null; then ok "防探测规则已持久化 (iptables service)"
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null || true
        run bash -c "iptables-save > /etc/iptables/rules.v4 2>/dev/null"
        run bash -c "ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true"
        ok "防探测规则已持久化 (iptables-save)"
    else warn "无法持久化防探测规则"; fi
    ok "防主动探测已启用: ${#TCP_PORTS[@]} TCP + ${#UDP_PORTS[@]} UDP + SSH + 单IP连接数上限 + IPv6对称（独立链 $CHAIN_ANTIPROBE）"
}

# ══════════ 主流程 ══════════
main() {
    logo() { :; }
    if $DRY_RUN; then echo -e "${YELLOW}═══ DRY-RUN 模式：仅预览，不修改系统 ═══${N}"; fi

    if [ -f "$CHECKPOINT" ] && [ -f /etc/s-box/sb.json ] && { systemctl is-active sb >/dev/null 2>&1 || systemctl is-active sing-box >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; }; then
        ok "sing-box 已部署运行中，跳过安装"; info "强制重装: rm -f $CHECKPOINT && bash deploy_singbox.sh"; return 0
    fi

    check_env || return 1
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




