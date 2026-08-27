#!/bin/bash
# lib/subscription.sh — 订阅管理
[ -n "${VPNPLUS_SUB_LOADED:-}" ] && return 0
VPNPLUS_SUB_LOADED=1

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


