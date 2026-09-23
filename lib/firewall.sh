#!/bin/bash
# lib/firewall.sh — 防火墙与端口跳跃
[ -n "${VPNPLUS_FIREWALL_LOADED:-}" ] && return 0
VPNPLUS_FIREWALL_LOADED=1

readonly HOP_HY_RANGE="40000:42000" # Hysteria2 端口跳跃段
readonly HOP_TU_RANGE="43000:45000" # Tuic5 端口跳跃段
readonly RATE_SYN_ABOVE=50
readonly RATE_SYN_BURST=100 # TCP 代理端口 SYN 限速 /sec、burst
readonly RATE_UDP_ABOVE=200
readonly RATE_UDP_BURST=400 # UDP 端口/跳跃段 限速 /sec、burst
readonly CONN_ABOVE=200     # 单 IP 单端口新建连接上限
readonly SSH_RATE_ABOVE=3
readonly SSH_RATE_BURST=5 # SSH 爆破防御 3/min、burst
CHAIN_PORTHOP="ACVPN_PORTHOP"
CHAIN_ANTIPROBE="ACVPN_ANTIPROBE"
CHAIN_RSS="ACVPN_RSS"
BAK_DIR="${BAK_DIR:-/var/backups/vpnplus}" # 规则备份目录（cleanup 用）
# 异构残留链（vpnmax 时代）：迁移期识别与清理用，新部署不再创建
LEGACY_CHAINS="VPNMAX_PORTHOP VPNMAX_ANTIPROBE VPNMAX_RSS"

# 品牌切割：拆除异构 VPNMAX_* 残留链（删跳转→flush→delete，v4+v6，filter+nat）。
# 调用时机：新链建成“之前”调一次做预清理；只碰明确属于旧品牌的链名，不碰第三方规则。
migrate_legacy_chains() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将拆除旧 VPNMAX_* 链"
        return 0
    fi
    local _c
    for _c in $LEGACY_CHAINS; do
        run iptables -D INPUT -j "$_c" 2>/dev/null || true
        run iptables -t nat -D PREROUTING -j "$_c" 2>/dev/null || true
        run iptables -F "$_c" 2>/dev/null || true
        run iptables -t nat -F "$_c" 2>/dev/null || true
        run iptables -X "$_c" 2>/dev/null || true
        run iptables -t nat -X "$_c" 2>/dev/null || true
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -D INPUT -j "$_c" 2>/dev/null || true
            run ip6tables -t nat -D PREROUTING -j "$_c" 2>/dev/null || true
            run ip6tables -F "$_c" 2>/dev/null || true
            run ip6tables -t nat -F "$_c" 2>/dev/null || true
            run ip6tables -X "$_c" 2>/dev/null || true
            run ip6tables -t nat -X "$_c" 2>/dev/null || true
        fi
    done
}

persist_firewall() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] 持久化 iptables 规则"
        return 0
    fi
    local saved=false
    if command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save 2>/dev/null; then
        ok "防火墙规则已持久化 (netfilter-persistent)"
        saved=true
    elif service iptables save 2>/dev/null; then
        ok "防火墙规则已持久化 (iptables service)"
        saved=true
    fi
    # 无论上述哪种成功，都额外保留一份明文快照 + 自建恢复 unit，双保险
    mkdir -p /etc/iptables 2>/dev/null || true
    command -v iptables-save >/dev/null 2>&1 && iptables-save 2>/dev/null | atomic_write /etc/iptables/rules.v4 || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save 2>/dev/null | atomic_write /etc/iptables/rules.v6 || true
    if [ -s /etc/iptables/rules.v4 ]; then
        atomic_write /etc/systemd/system/vpnplus-netfilter-restore.service <<'UNIT'
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

apply_antiprobe() {
    [ -f /etc/s-box/sb.json ] || {
        warn "sb.json 不存在，跳过防主动探测"
        return 1
    }
    info "配置防主动探测（独立链 $CHAIN_ANTIPROBE）..."
    local -a TCP_PORTS=() UDP_PORTS=()
    local VM_PORT="" p type tls_en

    while IFS='|' read -r p type tls_en; do
        [ -z "$p" ] || [ "$p" = "null" ] && continue
        if [ "$type" = "vmess" ] && [ "$tls_en" = "false" ]; then
            VM_PORT="$p"
        elif [ "$type" = "hysteria2" ] || [ "$type" = "tuic" ]; then
            UDP_PORTS+=("$p")
        else TCP_PORTS+=("$p"); fi
    done < <(jq -r '.inbounds[] | "\(.listen_port)|\(.type)|\(.tls.enabled // "false")"' /etc/s-box/sb.json 2>/dev/null || true)

    # 品牌切割：先拆异构 VPNMAX_* 残留链，再彻底重建新链（幂等且不碰第三方规则）
    if declare -F migrate_legacy_chains >/dev/null 2>&1; then migrate_legacy_chains || true; fi
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
    }
    i=$((i + 2))

    # 5) SSH 爆破防御（轻量 fail2ban）
    # SSH 端口不写死 22：2026-09-23 实测服务器 SSH 常在 6688，写死 22 等于保护了错端口。
    # 解析顺序：环境变量 SSH_PORT > sshd 自身解析（-T 已展开 Include，取全量多 Port）> 读配置（展 Include、跳 Match 块、取多 Port）> 22
    # Debian/Ubuntu 均 /etc/ssh/sshd_config + sshd_config.d/*.conf + /usr/sbin/sshd，语义一致。
    local _ssh_ports="" _p _main_ports _inc
    if [ -n "${SSH_PORT:-}" ]; then
        _ssh_ports="$SSH_PORT"
    else
        _ssh_ports=$(/usr/sbin/sshd -T -f /etc/ssh/sshd_config 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | sort -nu | tr '\n' ' ' || true)
        if [ -z "$_ssh_ports" ]; then
            _ssh_ports=$(/usr/sbin/sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}' | sort -nu | tr '\n' ' ' || true)
        fi
        if [ -z "$_ssh_ports" ]; then
            # 回退：手展 Include 行，跳过 Match 块内 Port（条件生效后端口不同，不做全局限速）
            _ssh_ports=$(awk '
                /^[[:space:]]*Include[[:space:]]+/ { for (i=2;i<=NF;i++) print $i; next }
                /^[[:space:]]*Port[[:space:]]+/ { print $2 }
            ' /etc/ssh/sshd_config 2>/dev/null | head -20 || true)
            for _inc in /etc/ssh/sshd_config.d/*.conf; do
                [ -f "$_inc" ] || continue
                _p=$(awk 'BEGIN{inmatch=0} /^[[:space:]]*Match[[:space:]]/ {inmatch=1; next} inmatch==0 && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ {print $2}' "$_inc" 2>/dev/null || true)
                [ -n "$_p" ] && _ssh_ports="$_ssh_ports $_p"
            done
            # 主文件 Match 块内 Port 同样排除
            _ssh_ports=$(printf '%s' "$_ssh_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' || true)
            _main_ports=$(awk 'BEGIN{inmatch=0} /^[[:space:]]*Match[[:space:]]/ {inmatch=1; next} inmatch==0 && /^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -nu | tr '\n' ' ' || true)
            if [ -n "$_main_ports" ]; then
                _ssh_ports="$_main_ports $_ssh_ports"
                _ssh_ports=$(printf '%s' "$_ssh_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' || true)
            fi
        fi
    fi
    _ssh_ports=$(printf '%s' "$_ssh_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' || true)
    [ -n "$_ssh_ports" ] || _ssh_ports="22"
    info "SSH 爆破防御目标端口: $_ssh_ports"
    for _p in $_ssh_ports; do
        run iptables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$_p" -m state --state NEW -m hashlimit \
            --hashlimit-above "$SSH_RATE_ABOVE"/min --hashlimit-burst "$SSH_RATE_BURST" --hashlimit-mode srcip --hashlimit-name probeSSH -j DROP
        command -v ip6tables >/dev/null 2>&1 && run ip6tables -A "$CHAIN_ANTIPROBE" -p tcp --dport "$_p" -m state --state NEW -m hashlimit \
            --hashlimit-above "$SSH_RATE_ABOVE"/min --hashlimit-burst "$SSH_RATE_BURST" --hashlimit-mode srcip --hashlimit-name probeSSH -j DROP || true
    done

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

config_port_hopping() {
    [ -f /etc/s-box/sb.json ] || {
        warn "sb.json 不存在，跳过端口跳跃"
        return 1
    }
    info "配置端口跳跃（独立链 $CHAIN_PORTHOP）..."
    local HY_PORT TU_PORT
    HY_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)

    # 品牌切割：先拆异构 VPNMAX_* 残留链
    if declare -F migrate_legacy_chains >/dev/null 2>&1; then migrate_legacy_chains || true; fi
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
        rnum=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null |
            awk -v hy="$HOP_HY_RANGE" -v tu="$HOP_TU_RANGE" '$2=="DNAT"||$2=="REDIRECT" { if ($0 ~ hy || $0 ~ tu) {print $1; exit} }')
        [ -z "$rnum" ] && break
        run iptables -t nat -D PREROUTING "$rnum" 2>/dev/null && {
            ok "清除残留规则 #$rnum"
            done_hop=true
        } || break
    done
    # v6 对称清理：与上段同条件镜像一条 ip6tables 循环（幂等、无 ip6tables 时跳过）
    if command -v ip6tables >/dev/null 2>&1; then
        while :; do
            local rnum6
            rnum6=$(ip6tables -t nat -L PREROUTING -n --line-numbers 2>/dev/null |
                awk -v hy="$HOP_HY_RANGE" -v tu="$HOP_TU_RANGE" '$2=="DNAT"||$2=="REDIRECT" { if ($0 ~ hy || $0 ~ tu) {print $1; exit} }')
            [ -z "$rnum6" ] && break
            run ip6tables -t nat -D PREROUTING "$rnum6" 2>/dev/null && {
                ok "清除残留规则(v6) #$rnum6"
                done_hop=true
            } || break
        done
    fi
    if [ "$done_hop" = false ]; then info "PREROUTING 端口跳跃段已干净，无需清理（幂等）"; fi

    if { [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; } || { [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; }; then
        run iptables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
        if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_HY_RANGE" -j DNAT --to-destination :"$HY_PORT"
            ok "Hysteria2 端口跳跃: ${HOP_HY_RANGE/:/-} → $HY_PORT"
        fi
        if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
            run iptables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_TU_RANGE" -j DNAT --to-destination :"$TU_PORT"
            ok "Tuic5 端口跳跃: ${HOP_TU_RANGE/:/-} → $TU_PORT"
        fi
        run iptables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -t nat -N "$CHAIN_PORTHOP" 2>/dev/null || true
            if [ -n "$HY_PORT" ] && [ "$HY_PORT" != "null" ]; then
                run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_HY_RANGE" -j DNAT --to-destination :"$HY_PORT"
                ok "Hysteria2 端口跳跃(v6): ${HOP_HY_RANGE/:/-} → $HY_PORT"
            fi
            if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
                run ip6tables -t nat -A "$CHAIN_PORTHOP" -p udp --dport "$HOP_TU_RANGE" -j DNAT --to-destination :"$TU_PORT"
                ok "Tuic5 端口跳跃(v6): ${HOP_TU_RANGE/:/-} → $TU_PORT"
            fi
            run ip6tables -t nat -A PREROUTING -j "$CHAIN_PORTHOP"
        else
            info "ip6tables 不存在，跳过 v6 跳跃规则（v4 已生效）"
        fi
    fi

    # iptables 持久化（统一走 persist_firewall：含自建恢复 unit，防重启丢失）
    persist_firewall
}

if ! declare -F bak_firewall >/dev/null 2>&1; then
    bak_firewall() {
        echo "--- 备份防火墙规则 ---"
        run mkdir -p "$BAK_DIR"
        local stamp
        stamp=$(date +%Y%m%d-%H%M%S)
        if command -v iptables-save >/dev/null 2>&1; then
            run bash -c "iptables-save > '$BAK_DIR/iptables.$stamp' 2>/dev/null"
            run bash -c "ip6tables-save > '$BAK_DIR/ip6tables.$stamp' 2>/dev/null || true"
            ok "iptables 规则已备份到 $BAK_DIR (iptables.$stamp)"
        fi
        if command -v nft >/dev/null 2>&1; then
            run bash -c "nft list ruleset > '$BAK_DIR/nftables.$stamp' 2>/dev/null || true"
        fi
    }
fi

if ! declare -F clean_chains >/dev/null 2>&1; then
    clean_chains() {
        echo "--- 清理 vpnplus 独立防火墙链 ---"
        run iptables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null
        run iptables -D INPUT -j "$CHAIN_RSS" 2>/dev/null
        run iptables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null
            run ip6tables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null
        fi
        run iptables -F "$CHAIN_ANTIPROBE" 2>/dev/null
        run iptables -X "$CHAIN_ANTIPROBE" 2>/dev/null
        run iptables -F "$CHAIN_RSS" 2>/dev/null
        run iptables -X "$CHAIN_RSS" 2>/dev/null
        run iptables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null
        run iptables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null
        if command -v ip6tables >/dev/null 2>&1; then
            run ip6tables -F "$CHAIN_ANTIPROBE" 2>/dev/null
            run ip6tables -X "$CHAIN_ANTIPROBE" 2>/dev/null
            run ip6tables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null
            run ip6tables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null
        fi
        command -v iptables >/dev/null 2>&1 && {
            iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null |
                grep -E '(DNAT|REDIRECT).*dpts:(40000:42000|43000:45000|40000:41000|43000:44000) ' |
                awk '{print $1}' | sort -rn | while read -r num; do
                run iptables -t nat -D PREROUTING "$num"
            done
        }
        # v6 对称清理：同条件镜像删 ip6tables PREROUTING 残留（无 ip6tables 时跳过）
        command -v ip6tables >/dev/null 2>&1 && {
            ip6tables -t nat -L PREROUTING --line-numbers -n 2>/dev/null |
                grep -E '(DNAT|REDIRECT).*dpts:(40000:42000|43000:45000|40000:41000|43000:44000) ' |
                awk '{print $1}' | sort -rn | while read -r num; do
                run ip6tables -t nat -D PREROUTING "$num"
            done
        } || true
        ok "独立防火墙链已清理（未触碰第三方规则）"
    }
fi
