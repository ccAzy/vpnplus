#!/bin/bash
# lib/argo.sh — Argo 隧道
[ -n "${VPNPLUS_ARGO_LOADED:-}" ] && return 0
VPNPLUS_ARGO_LOADED=1

# argo-extra.conf 白名单校验（对齐 vpnmax a28fe7e 系 P0-5 root RCE 防线）。
# 规则：注释/# 与空行跳过；含 shell 元字符（;|&$``()<>!"'）整行丢弃并告警；
# 仅放行 `--flag` 与 `[A-Za-z0-9.:=_/-]` 值 token。返回空格分隔的安全参数串。
vpnplus_argo_extra_args() {
    local extra="${1:-}" line tok ok_args=""
    [ -s "$extra" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        if printf '%s' "$line" | tr -d 'A-Za-z0-9 _.:=/-' | grep -q .; then
            printf '[!]   argo-extra.conf 含 shell 元字符，整行丢弃：%.80s\n' "$line" >&2
            continue
        fi
        for tok in $line; do
            if printf '%s' "$tok" | grep -qE '^--[a-z-]+$|^[A-Za-z0-9.:=_/-]+$'; then
                ok_args="$ok_args $tok"
            else
                printf '[!]   argo-extra.conf 非法 token，已丢弃：%.40s\n' "$tok" >&2
            fi
        done
    done <"$extra"
    printf '%s' "$ok_args"
}

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



# sb 菜单启动的隧道不读 argo-extra.conf（优选参数进不去）。
# 部署后对齐一次：若 extra 非空且当前隧道命令行缺优选参数，则受控重启带上。
# 幂等：已带参数则跳过；重启后只留单实例。
ensure_argo_extra_applied() {
    local extra="/etc/s-box/argo-extra.conf"
    [ -s "$extra" ] || return 0
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将对齐 argo-extra.conf 到运行隧道"
        return 0
    fi
    local want_run cur_run
    want_run=$(vpnplus_argo_extra_args "$extra" || true)
    [ -z "$(echo "$want_run" | tr -d ' ')" ] && return 0
    cur_run=$(pgrep -af 'cloudflared.*tunnel.*--url' 2>/dev/null | head -1 || true)
    [ -z "$cur_run" ] && return 0
    # 精确比对：extra 里的具体值（如 --edge-ip-version 4）必须出现在运行命令行里，
    # 只含同名不同值（如 auto）也算缺失，避免 sb 默认 auto 蒙混过关。
    local _missing=0 _need="" _tok _v
    for _tok in --edge-ip-version --region --edge-bind-address; do
        _v=$(echo "$want_run" | grep -oE -- "$_tok [^ ]+" | head -1 || true)
        if [ -n "$_v" ] && ! echo "$cur_run" | grep -qF -- "$_v"; then
            _missing=1
            _need="$_need $_v"
        fi
    done
    if [ "$_missing" = 0 ]; then
        ok "运行隧道已带优选参数，无需对齐"
        return 0
    fi
    info "运行隧道缺优选参数 ($_need)，受控重启一次带上..."
    local wsport
    wsport=$(jq -r '[.inbounds[] | select(.type=="vless" and .transport.type=="ws") | .listen_port][0] // empty' /etc/s-box/sb.json 2>/dev/null)
    [ -n "$wsport" ] && [ "$wsport" != "null" ] || wsport=$(jq -r '.inbounds[1].listen_port // empty' /etc/s-box/sb.json 2>/dev/null)
    [ -n "$wsport" ] || { warn "WS 端口解析失败，跳过对齐"; return 0; }
    local cfbin
    cfbin=$(command -v cloudflared 2>/dev/null)
    [ -x "${cfbin:-}" ] || cfbin=$(ls /etc/s-box/cloudflared /usr/local/bin/cloudflared 2>/dev/null | head -1)
    [ -x "${cfbin:-}" ] || { warn "cloudflared 缺失，跳过对齐"; return 0; }
    pkill -9 -f 'cloudflared.*tunnel.*--url' 2>/dev/null || true
    sleep 3
    # 数组传参：want_run 已过白名单（仅 --flag 与安全值），杜绝无引号拼接注入
    local -a want_arr=()
    read -ra want_arr <<< "$want_run" || true
    nohup "$cfbin" tunnel --url "http://localhost:$wsport" --no-autoupdate --protocol auto "${want_arr[@]}" >/etc/s-box/argo.log 2>&1 &
    sleep 20
    local cnt
    cnt=$(pgrep -c -f 'cloudflared.*tunnel.*--url' 2>/dev/null || echo 0)
    if [ "$cnt" -eq 1 ] && grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | tail -1 | grep -q .; then
        ok "隧道已带优选参数重启（单实例，域名已更新，订阅由 keepalive L3 同步）"
    else
        warn "对齐后隧道异常（进程数 $cnt），keepalive 下轮自动修复"
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
    # G4修复：@reboot cron 与 keepalive 竞态会导致双进程；启动后只保留最新一个
    : > "$LOG"
    # P0-5：extra 参数只取白名单 token（--flag 与安全值），元字符整行丢弃，不直接 cat 拼接
    EXTRA_ARGS=$(grep -v '^#' /etc/s-box/argo-extra.conf 2>/dev/null | grep -oE -- '--[a-z-]+|[A-Za-z0-9.:=_/-]+' | tr '\n' ' ' || true)
    # shellcheck disable=SC2086 # EXTRA_ARGS 已是白名单提取结果，无元字符
    nohup "$CF_BIN" tunnel --url "http://localhost:$WS_PORT" \
      --edge-ip-version auto --no-autoupdate --protocol auto \
      $EXTRA_ARGS > "$LOG" 2>&1 &
    sleep 2
    pids=$(pgrep -f "$TUN_RUNS" 2>/dev/null || true)
    if [ "$(echo "$pids" | wc -l)" -gt 1 ]; then
        newest=$(echo "$pids" | tail -1)
        for p in $pids; do [ "$p" != "$newest" ] || continue; kill -9 "$p" 2>/dev/null || true; done
        logger -t vpnplus-argo "启动后发现多实例，已只保留最新 PID $newest（防 cron/keepalive 竞态）"
    fi
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
# G7修复：旧逻辑只看 jhsub.txt 且该文件可能根本不含域名（直接跳过）；
# 现遍历全部 Argo 订阅产物，有域名残留但与运行域不一致即补同步，同步后复验，仍失败则明示手动。
SUB_ARGO_FILES="/etc/s-box/jhsub.txt /etc/s-box/jhdy.txt /etc/s-box/clmi.yaml /etc/s-box/sbox.json /etc/s-box/vm_ws_argols.txt"
if [ -n "$OLD_URL" ]; then
    OLD_DOM=$(echo "$OLD_URL" | sed 's|https://||')
    need_sync=0
    for sf in $SUB_ARGO_FILES; do
        if [ -f "$sf" ] && grep -q 'trycloudflare' "$sf" 2>/dev/null; then
            grep -q "$OLD_DOM" "$sf" 2>/dev/null || need_sync=1
        fi
    done
    if [ "$need_sync" = 1 ]; then
        refresh_sub
        sleep 3
        still_old=0
        for sf in $SUB_ARGO_FILES; do
            if [ -f "$sf" ] && grep -q 'trycloudflare' "$sf" 2>/dev/null; then
                grep -q "$OLD_DOM" "$sf" 2>/dev/null || still_old=1
            fi
        done
        if [ "$still_old" = 1 ]; then
            logger -t vpnplus-argo "L3补同步后订阅仍与运行域名 $OLD_DOM 不一致，sb 菜单可能已漂移，需手动: sb → 9 → 1"
        else
            logger -t vpnplus-argo "L3订阅与运行域名不一致, 已补同步"
        fi
    fi
fi
exit 0
KEEP
        chmod +x /usr/local/sbin/vpnplus-argo-keepalive.sh
        ( crontab -l 2>/dev/null | grep -vE 'vpnplus-argo-keepalive|acvn-argo-keepalive|acvpn-argo-keepalive'; echo '*/3 * * * * /usr/local/sbin/vpnplus-argo-keepalive.sh > /dev/null 2>&1' ) | crontab - 2>/dev/null || true
    fi
    ok "Argo 保活 v3 已安装（每 3 分钟：flock互斥 + 进程/HTTP 双检 + 僵死重连换域名同步订阅 + 翻动冷却）"
}


