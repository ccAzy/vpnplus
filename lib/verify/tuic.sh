#!/bin/bash
# lib/verify/tuic.sh — TUIC 端口污染与回环自检
[ -n "${VPNPLUS_VERIFY_TUIC_LOADED:-}" ] && return 0
VPNPLUS_VERIFY_TUIC_LOADED=1

verify_tuic() {
    local TU_PORT
    TU_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port' /etc/s-box/sb.json 2>/dev/null || true)
    [ -z "$TU_PORT" ] || [ "$TU_PORT" = "null" ] && return 0
    if [ "$TU_PORT" = "40254" ]; then warn "TUIC 仍为 40254（已知易被运营商限速，建议切 54321 并重建跳跃 DNAT）"; else ok "TUIC 端口 $TU_PORT 非已知污染端口"; fi
    if iptables -t nat -L "$CHAIN_PORTHOP" -n 2>/dev/null | grep -q "to::${TU_PORT}"; then ok "端口跳跃 DNAT 指向 TUIC $TU_PORT"; else warn "端口跳跃 DNAT 未指向 TUIC $TU_PORT（43000:45000 应 DNAT 到 :$TU_PORT）"; fi
    if [ -n "$TU_PORT" ] && command -v /etc/s-box/sing-box >/dev/null 2>&1; then
        local _tuic_uuid
        _tuic_uuid=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid' /etc/s-box/sb.json 2>/dev/null || true)
        if [ -n "$_tuic_uuid" ] && [ "$_tuic_uuid" != "null" ]; then
            local _port
            _port=$(shuf -i 18080-19090 -n1 2>/dev/null || echo 18081)
            cat > /tmp/vpnplus-verify-tuic.json <<JSON_TMP
{"log":{"level":"error"},"inbounds":[{"type":"socks","listen":"127.0.0.1","listen_port":$_port}],"outbounds":[{"type":"tuic","server":"127.0.0.1","server_port":$TU_PORT,"uuid":"$_tuic_uuid","password":"$_tuic_uuid","congestion_control":"bbr","tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}]}
JSON_TMP
            timeout 4 /etc/s-box/sing-box run -c /tmp/vpnplus-verify-tuic.json > /tmp/vpnplus-verify-tuic.log 2>&1 & local _vpid=$!; sleep 2
            if curl -s -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:"$_port" --connect-timeout 4 --max-time 6 https://www.google.com/generate_204 2>/dev/null | grep -q '204'; then ok "TUIC 本地回环自检通（127.0.0.1:$TU_PORT → google 204）"; else warn "TUIC 本地回环不通（本机 sing-box 或证书异常，非外网墙）"; fi
            kill -9 $_vpid 2>/dev/null || true; rm -f /tmp/vpnplus-verify-tuic.json /tmp/vpnplus-verify-tuic.log 2>/dev/null || true
        fi
    fi
}
