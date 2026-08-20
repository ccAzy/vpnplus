#!/bin/bash
# ===================================================================
# vpnplus — 部署后验证脚本
# 检查 sing-box 进程、端口、独立防火墙链、Argo 隧道、订阅链接、域名分流
#
# 与旧版差异：验证独立命名链（ACVPN_PORTHOP / ACVPN_ANTIPROBE）是否存在，
#   不再 grep 全局 INPUT/PREROUTING 规则（旧法易误判/误删第三方规则）。
# 用法: bash verify.sh [SERVER_IP]
# ===================================================================
set -uo pipefail

SERVER_IP="${1:-}"
VMESS_LOCK="${VMESS_LOCK:-on}"
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
else
    warn "持久化网络调优服务未运行（可能尚未执行 deploy_optimize.sh）"
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
if iptables -L "$CHAIN_ANTIPROBE" -n >/dev/null 2>&1; then ok "防探测链 ${CHAIN_ANTIPROBE:-ACVPN_ANTIPROBE} 存在"; PASS=$((PASS + 1)); else warn "防探测链不存在"; fi

if [ "$VMESS_LOCK" = "on" ]; then
    if iptables-save 2>/dev/null | grep -q '! -i lo'; then
        ok "VMess 明文端口公网封锁中"; PASS=$((PASS + 1))
    else
        warn "未检测到 VMess 明文端口回环锁定规则"
    fi
else
    info "VMESS_LOCK=off：跳过明文 VMess 公网封锁检查"
fi

# 4. Argo
echo "--- Argo 隧道 ---"
if [ -f /etc/s-box/argo.log ]; then
    ARGO_URL=$(grep -ao 'https://[a-z0-9.-]*\.trycloudflare\.com' /etc/s-box/argo.log 2>/dev/null | head -1)
    if [ -n "$ARGO_URL" ]; then
        ok "Argo 隧道: $ARGO_URL"; PASS=$((PASS + 1))
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$ARGO_URL" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then ok "Argo 端点可达 (HTTP $HTTP_CODE)"; PASS=$((PASS + 1)); else warn "Argo 端点不可达"; fi
    else
        fail "argo.log 中未找到 trycloudflare.com URL"; FAIL=$((FAIL + 1))
    fi
else
    fail "/etc/s-box/argo.log 不存在"; FAIL=$((FAIL + 1))
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
