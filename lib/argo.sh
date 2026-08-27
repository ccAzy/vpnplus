#!/bin/bash
# lib/argo.sh — Argo 隧道
[ -n "${VPNPLUS_ARGO_LOADED:-}" ] && return 0
VPNPLUS_ARGO_LOADED=1

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


