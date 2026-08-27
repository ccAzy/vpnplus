#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnplus — 部署后验证脚本
# 检查 sing-box 进程、端口、独立防火墙链、Argo 隧道、订阅链接、域名分流
#
# 与旧版差异：验证独立命名链（ACVPN_PORTHOP / ACVPN_ANTIPROBE）是否存在，
#   不再 grep 全局 INPUT/PREROUTING 规则（旧法易误判/误删第三方规则）。
# 用法: bash verify.sh [SERVER_IP]
# ===================================================================
set -euo pipefail

# lib 加载（verify 侧仅需 time/tuic 检查，失败则用内联兜底）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in common time verify/time verify/tuic; do
    if [ -f "$SCRIPT_DIR/lib/${_lib}.sh" ]; then source "$SCRIPT_DIR/lib/${_lib}.sh" 2>/dev/null || true
    elif [ -f "lib/${_lib}.sh" ]; then source "lib/${_lib}.sh" 2>/dev/null || true
    fi
done

SERVER_IP="${SERVER_IP:-${1:-}}"   # 兼容两种用法：SERVER_IP=x.x.x.x bash verify.sh 或 bash verify.sh x.x.x.x
VMESS_LOCK="${VMESS_LOCK:-off}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
fail() { echo -e "${RED}[✗]${N}   $*"; }
info() { echo -e "${CYAN}[*]${N}   $*"; }

PASS=0; FAIL=0
CHAIN_PORTHOP="ACVPN_PORTHOP"
CHAIN_ANTIPROBE="ACVPN_ANTIPROBE"
check() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then ok "$desc"; PASS=$((PASS + 1)); return 0
    else fail "$desc"; FAIL=$((FAIL + 1)); return 1; fi
}

echo ""
echo "========================================="
echo "  vpnplus 部署验证"
echo "========================================="
echo ""

# 1. 基础
echo "--- 基础状态 ---"
check "sb 命令存在" command -v sb
SB_BIN=""; for _b in /usr/bin/sing-box /usr/local/bin/sing-box /etc/s-box/sing-box; do [ -x "$_b" ] && { SB_BIN="$_b"; break; }; done
check "sing-box 二进制" [ -n "$SB_BIN" ]
check "/etc/s-box 目录" [ -d /etc/s-box ]

if command -v modinfo >/dev/null 2>&1; then
    if modinfo tcp_bbr 2>/dev/null | grep -qi 'bbr3\|bbr v3'; then
        ok "BBRv3 内核模块已就位"; PASS=$((PASS + 1))
    else
        warn "tcp_bbr 为主线 BBRv1（未启用 BBRv3 内核，先执行 deploy_optimize.sh）"
    fi
else
    warn "modinfo 不可用，跳过 BBRv3 检测"
fi

IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
if [ -n "$IFACE" ] && command -v ethtool >/dev/null 2>&1; then
    if ethtool -k "$IFACE" 2>/dev/null | grep -q 'tx-udp-segmentation: on'; then
        ok "UDP 分段卸载已开启（Hy2/Tuic）"; PASS=$((PASS + 1))
    else
        warn "UDP 分段卸载未开启或驱动不支持"
    fi
fi
if [ -n "$IFACE" ] && command -v tc >/dev/null 2>&1; then
    if tc qdisc show dev "$IFACE" 2>/dev/null | grep -qE '(^| )fq([ _]|$)'; then
        ok "默认网卡 fq 队列调度已启用"; PASS=$((PASS + 1))
    else
        warn "默认网卡未检测到 fq 队列调度"
    fi
fi
if systemctl is-active --quiet vpnplus-net-tuning.service 2>/dev/null; then
    ok "持久化网络调优服务运行中"; PASS=$((PASS + 1))
    systemctl is-enabled --quiet vpnplus-net-tuning.service 2>/dev/null && ok "网络调优服务已启用(开机自启)" || warn "网络调优服务未 enable"
else
    warn "持久化网络调优服务未运行（可能尚未执行 deploy_optimize.sh）"
fi

# 防火墙持久化恢复单元（#2026-08-25：防重启后 ACVPN_* 链丢失）
if [ -f /etc/systemd/system/vpnplus-netfilter-restore.service ]; then
    ok "vpnplus-netfilter-restore.service 存在"; PASS=$((PASS + 1))
    systemctl is-enabled --quiet vpnplus-netfilter-restore.service 2>/dev/null && ok "防火墙恢复单元已启用" || warn "防火墙恢复单元未 enable"
else
    warn "未检测到 vpnplus-netfilter-restore.service（重启后端口跳跃/防探测规则可能不自动恢复）"
fi
# 日志轮转配置
if [ -f /etc/logrotate.d/vpnplus ]; then ok "日志轮转配置存在"; PASS=$((PASS + 1)); else warn "未检测到 logrotate 配置"; fi

# 1a. SSH 仅密钥（P0：密码泄露=整机沦陷）
echo "--- SSH 加固 ---"
if grep -qE "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then ok "PasswordAuthentication no（仅密钥）"; PASS=$((PASS+1)); else fail "PasswordAuthentication 未设 no（仍允许密码，风险高）"; FAIL=$((FAIL+1)); fi
if sshd -T -f /etc/ssh/sshd_config 2>/dev/null | grep -qi "^passwordauthentication no"; then ok "sshd -T 验证 PasswordAuthentication no"; PASS=$((PASS+1)); else warn "sshd -T 仍为 yes（可能被 Include 覆盖，需检查 sshd_config.d）"; fi
if [ -f /usr/local/etc/sshd_config ] && ! grep -qE "^PasswordAuthentication no" /usr/local/etc/sshd_config 2>/dev/null; then warn "/usr/local/etc/sshd_config 未加固（若使用 /usr/local/sbin/sshd 则风险）"; fi
if grep -qE "^PermitRootLogin prohibit-password" /etc/ssh/sshd_config 2>/dev/null; then ok "PermitRootLogin prohibit-password"; PASS=$((PASS+1)); else warn "PermitRootLogin 未设 prohibit-password"; fi
# 1b. sing-box 1.12+ legacy 环境变量（2026-08-27 JP/HK 崩溃根因）
echo "--- sing-box 兼容 ---"
if grep -q "ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" /etc/systemd/system/sing-box.service.d/99-vpnplus.conf 2>/dev/null; then ok "sing-box legacy env 已注入"; PASS=$((PASS+1)); else warn "sing-box legacy env 缺失（1.12+ 会 FATAL 崩溃，需 ensure_singbox_legacy_env）"; fi
if grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null && [ "$(grep -c "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null)" -eq 1 ]; then ok "gai.conf IPv4 优先单行"; PASS=$((PASS+1)); else warn "gai.conf 重复或缺失 precedence ::ffff:0:0/96 100（去重后应为单行）"; fi

# 1b. 时间同步（P0：Reality/VMess 握手对时，漂移>90s 全不通，但端口照常通）
if declare -F verify_time >/dev/null 2>&1; then verify_time; else
    echo "--- 时间同步 ---"
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then ok "chrony 已同步（Leap Normal）"; PASS=$((PASS + 1)); else warn "chrony 未 Normal（$(chronyc tracking 2>/dev/null | grep 'Leap status' | head -1)）"; fi
        if chronyc sources -v 2>/dev/null | grep -q '\^'; then ok "chrony 源可达"; PASS=$((PASS + 1)); else warn "chrony 源不可达或未配置国内源"; fi
    else
        warn "chrony 未安装（时间漂移会导致 bad timestamp 全不通，建议 apt install chrony）"
    fi
    if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then ok "System clock synchronized: yes"; PASS=$((PASS + 1)); else warn "System clock synchronized: no（timedatectl）"; fi
    _off=$(timeout 5 ntpdate -q ntp.aliyun.com 2>&1 | grep -oE 'offset .* sec' | head -1 || true)
    [ -n "$_off" ] && info "NTP 偏移: $_off"
fi

# 2. 进程
echo "--- 进程检查 ---"
if pgrep -f sing-box >/dev/null; then
    ok "sing-box 进程运行中"; PASS=$((PASS + 1))
    pgrep -af sing-box 2>/dev/null | while read -r line; do info "$line"; done || true
else
    fail "sing-box 进程未运行"; FAIL=$((FAIL + 1))
fi

# 3. 端口 + 独立防火墙链
echo "--- 端口与防火墙 ---"
PORTS=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | grep -oE '[0-9]+$' | sort -n | tr '\n' ' ' || true)
if [ -n "$PORTS" ]; then ok "监听端口: $PORTS"; PASS=$((PASS + 1)); else fail "未检测到 sing-box 监听端口"; FAIL=$((FAIL + 1)); fi
if ss -ulnp 2>/dev/null | grep -q sing-box; then ok "UDP 端口监听正常（Hysteria2）"; PASS=$((PASS + 1)); else warn "未检测到 UDP 端口"; fi

# 独立命名链存在性（vpnplus 防火墙设计核心）
if iptables -t nat -L "$CHAIN_PORTHOP" -n >/dev/null 2>&1; then ok "端口跳跃链 ${CHAIN_PORTHOP:-ACVPN_PORTHOP} 存在"; PASS=$((PASS + 1)); else warn "端口跳跃链不存在（可能未配置端口跳跃）"; fi
# PREROUTING 是否残留指向过期端口的孤立跳跃段规则（会导致 hy2/tuic 端口跳跃握手无响应）
# 注意：40000:42000 / 43000:45000 与 deploy_singbox.sh 顶部的 HOP_HY_RANGE / HOP_TU_RANGE 保持同步
HOP_LEAK=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "DNAT|REDIRECT" | grep -E "40000:42000|43000:45000" | grep -v "ACVPN_PORTHOP" | head -1 || true)
if [ -n "$HOP_LEAK" ]; then warn "检测到 PREROUTING 残留过期端口跳跃规则: $HOP_LEAK（重跑 deploy_singbox.sh 会自动清理）"; else ok "PREROUTING 无残留端口跳跃段"; PASS=$((PASS + 1)); fi
if iptables -L "$CHAIN_ANTIPROBE" -n >/dev/null 2>&1; then ok "防探测链 ${CHAIN_ANTIPROBE:-ACVPN_ANTIPROBE} 存在"; PASS=$((PASS + 1)); else warn "防探测链不存在"; fi

# 3b. TUIC 端口可用性（P0：40254 为已知易被墙端口）
if declare -F verify_tuic >/dev/null 2>&1; then verify_tuic; else
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ]; then
        if [ "$TU_PORT" = "40254" ]; then warn "TUIC 仍为 40254（已知易被运营商限速，建议切 54321 并重建跳跃 DNAT）"; else ok "TUIC 端口 $TU_PORT 非已知污染端口"; PASS=$((PASS + 1)); fi
        if iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${TU_PORT}"; then ok "端口跳跃 DNAT 指向 TUIC $TU_PORT"; PASS=$((PASS + 1)); else warn "端口跳跃 DNAT 未指向 TUIC $TU_PORT（43000:45000 应 DNAT 到 :$TU_PORT）"; fi
    fi
    if [ -n "$TU_PORT" ] && [ "$TU_PORT" != "null" ] && command -v /etc/s-box/sing-box >/dev/null 2>&1; then
        _tuic_uuid=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid' /etc/s-box/sb.json 2>/dev/null || true)
        if [ -n "$_tuic_uuid" ] && [ "$_tuic_uuid" != "null" ]; then
            _vport=$(shuf -i 18080-19090 -n1 2>/dev/null || echo 18081)
            cat > /tmp/vpnplus-verify-tuic.json <<JSON_TMP
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":$_vport}],"outbounds":[{"type":"tuic","server":"127.0.0.1","server_port":$TU_PORT,"uuid":"$_tuic_uuid","password":"$_tuic_uuid","congestion_control":"bbr","tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}]}
JSON_TMP
            timeout 4 /etc/s-box/sing-box run -c /tmp/vpnplus-verify-tuic.json > /tmp/vpnplus-verify-tuic.log 2>&1 & _vpid=$!; sleep 2
            if curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:$_vport --connect-timeout 4 --max-time 6 https://www.google.com/generate_204 2>/dev/null | grep -q '204'; then ok "TUIC 本地回环自检通（127.0.0.1:$TU_PORT → google 204）"; PASS=$((PASS + 1)); else warn "TUIC 本地回环不通（本机 sing-box 或证书异常，非外网墙）"; fi
            kill -9 $_vpid 2>/dev/null || true; rm -f /tmp/vpnplus-verify-tuic.json /tmp/vpnplus-verify-tuic.log 2>/dev/null || true
        fi
    fi
fi

if [ "$VMESS_LOCK" = "on" ]; then
    if iptables-save 2>/dev/null | grep -q '! -i lo'; then
        ok "VMess 明文端口公网封锁中"; PASS=$((PASS + 1))
    else
        warn "未检测到 VMess 明文端口回环锁定规则"
    fi
else
    info "VMESS_LOCK=off：跳过明文 VMess 公网封锁检查"
fi

# 3c. 三处对齐（sb.json vs clmi.yaml vs iptables）— 捕获 rn1 40254/54321 岔裂
# 自动化比对：sb.json 的每个 inbound 端口 是否等于 clmi.yaml 同名 proxy 的 port，且跳跃 DNAT 是否指向它
if [ -f /etc/s-box/sb.json ] && [ -f /etc/s-box/clmi.yaml ]; then
    echo "--- 三处对齐 ---"
    _align_ok=true
    while IFS='|' read -r _sb_port _sb_type; do
        [ -z "$_sb_port" ] || [ "$_sb_port" = "null" ] && continue
        # 跳过 vmess-argo 等 clmi 中 server 为 cloudflare 的项，只比直连
        _clmi_port=$(grep -A2 "type: $_sb_type" /etc/s-box/clmi.yaml 2>/dev/null | grep -oE 'port: [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
        # 若 sb.json 某类型在 clmi 找不到（比如 argo），跳过
        [ -z "$_clmi_port" ] && continue
        if [ "$_sb_port" != "$_clmi_port" ]; then
            warn "三处岔裂: sb.json $_sb_type $_sb_port ≠ clmi.yaml $_clmi_port（订阅与监听不一致，客户端按订阅连会不通）"
            _align_ok=false
        fi
    done < <(jq -r '.inbounds[] | "\(.listen_port)|\(.type)"' /etc/s-box/sb.json 2>/dev/null || true)
    $_align_ok && { ok "sb.json 与 clmi.yaml 端口一致"; PASS=$((PASS + 1)); }
    # 额外：若 sb.json TUIC 已是 54321 但 iptables 仍指 40254，也算岔裂（上次 rn1 就是）
    _tu_now=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    if [ -n "$_tu_now" ] && [ "$_tu_now" != "null" ] && ! iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${_tu_now}"; then
        warn "三处岔裂: iptables 跳跃未指向当前 TUIC $_tu_now（$CHAIN_PORTHOP 需 DNAT 43000:45000→:$_tu_now）"
    fi
fi

# 4. Argo
echo "--- Argo 隧道 ---"
if [ -f /etc/s-box/argo.log ]; then
    ARGO_URL=$(grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | head -1)
    if [ -n "$ARGO_URL" ]; then
        ok "Argo 隧道: $ARGO_URL"; PASS=$((PASS + 1))
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$ARGO_URL" 2>/dev/null || echo "000")
        # 隧道代理的是 sing-box WS 服务：根路径 404/4xx 属正常响应（能拿到状态码=Cloudflare 边缘→隧道→本地链路通）
        # 只有 000（连不上边缘/超时）才算不可达
        if [ "$HTTP_CODE" != "000" ]; then ok "Argo 端点可达 (HTTP $HTTP_CODE，根路径无内容属正常)"; PASS=$((PASS + 1)); else warn "Argo 端点不可达"; fi
    else
        fail "argo.log 中未找到 trycloudflare.com URL"; FAIL=$((FAIL + 1))
    fi
else
    fail "/etc/s-box/argo.log 不存在"; FAIL=$((FAIL + 1))
fi

# Argo 自愈保活（v3）：脚本存在 + cron 每 3 分钟 + flock 依赖可用
if [ -x /usr/local/sbin/vpnplus-argo-keepalive.sh ]; then
    ok "Argo 保活脚本存在"; PASS=$((PASS + 1))
    if crontab -l 2>/dev/null | grep -q 'vpnplus-argo-keepalive'; then ok "保活 cron 已注册(每3分钟)"; PASS=$((PASS + 1)); else warn "保活 cron 未注册"; fi
    command -v flock >/dev/null 2>&1 && ok "flock 可用(保活互斥)" || warn "flock 缺失(util-linux)";
else
    warn "Argo 保活脚本不存在（重跑 deploy_singbox.sh 可重建）"
fi

# 5. 订阅链接
echo "--- 订阅链接 ---"
if [ -f /etc/s-box/subport.log ] && [ -f /etc/s-box/subtoken.log ]; then
    SUBPORT=$(cat /etc/s-box/subport.log); SUBTOKEN=$(cat /etc/s-box/subtoken.log)
    ok "订阅端口: $SUBPORT"
    if [ -n "$SERVER_IP" ]; then
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://${SERVER_IP}:${SUBPORT}/${SUBTOKEN}/${fmt}" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "200" ]; then ok "$fmt 可访问 (HTTP 200)"; PASS=$((PASS + 1)); else fail "$fmt 不可访问 (HTTP $HTTP_CODE)"; FAIL=$((FAIL + 1)); fi
        done
    else
        LOCAL_HTTP=000
        for fmt in clmi.yaml sbox.json jhsub.txt; do
            LOCAL_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:${SUBPORT}/${SUBTOKEN}/${fmt}" 2>/dev/null || echo "000")
            [ "$LOCAL_HTTP" = "200" ] && { ok "$fmt 本机可访问 (HTTP 200)"; break; }
        done
        if [ "$LOCAL_HTTP" = "200" ]; then PASS=$((PASS + 1)); else fail "订阅服务未响应（本机 HTTP $LOCAL_HTTP）— 检查 busybox httpd"; FAIL=$((FAIL + 1)); fi
    fi
else
    fail "订阅配置文件缺失 (subport.log / subtoken.log)"; FAIL=$((FAIL + 1))
fi

# 6. 域名分流
echo "--- 域名分流 ---"
if [ -f /etc/s-box/sbwpph.json ]; then
    DOMAIN_COUNT="?"
    if command -v python3 >/dev/null 2>&1; then
        DOMAIN_COUNT=$(python3 -c "import json; print(len(json.load(open('/etc/s-box/sbwpph.json'))['route']['rules'][0].get('domain',[])))" 2>/dev/null || echo "?")
    fi
    ok "域名分流文件存在 (${DOMAIN_COUNT} 个域名)"; PASS=$((PASS + 1))
else
    warn "sbwpph.json 不存在（可能未配置域名分流）"
fi

echo ""
echo "========================================="
echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
echo "========================================="
[ $FAIL -eq 0 ] && echo -e "${GREEN}部署验证全部通过。${N}" || { echo -e "${RED}存在失败项，请按上方提示排查。${N}"; exit 1; }
