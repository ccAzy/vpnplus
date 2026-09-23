#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/hardening.sh — 系统安全加固（网络感知 sysctl + systemd LimitNOFILE）
# 依赖 lib/common.sh 的 info/ok/warn/run/atomic_write
# 仅收紧自家资产（sysctl 文件 + sing-box 系 drop-in），不碰 ufw/整机 iptables 策略。

[ -n "${VPNPLUS_HARDENING_LOADED:-}" ] && return 0
VPNPLUS_HARDENING_LOADED=1

apply_hardening() {
    local conf="/etc/sysctl.d/99-vpnplus-security.conf"
    # RP 过滤覆盖：direct/策略路由场景需 loose(2)，否则回包被丢。默认 strict(1)。
    # 用法: VPNPLUS_RP_FILTER=2 bash deploy_singbox.sh（direct/多出口/策略路由时用 2）
    local rp="${VPNPLUS_RP_FILTER:-1}"
    case "$rp" in 1|2) ;; *) warn "VPNPLUS_RP_FILTER=$rp 非法，回退 1"; rp=1 ;; esac
    [ "$rp" = "2" ] && info "RP 过滤已放宽为 loose(2，direct/策略路由覆盖)"
    local v6_ra_lines
    # 检测本机是否有 IPv6 地址（无 v6 才关 RA，避免破坏依赖 RA 获址的 VPS）
    if ! ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then
        v6_ra_lines=$'net.ipv6.conf.all.accept_ra = 0\nnet.ipv6.conf.default.accept_ra = 0'
    else
        v6_ra_lines='# 检测到 IPv6 地址，保留 RA 以防破坏 v6 网络配置'
    fi
    atomic_write "$conf" <<SEC
# vpnplus 安全加固（网络感知生成；rp_filter 可经 VPNPLUS_RP_FILTER=1|2 覆盖）
net.ipv4.conf.all.rp_filter = $rp
net.ipv4.conf.default.rp_filter = $rp
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
SEC
    sysctl --system >/dev/null 2>&1 || true
    ok "安全 sysctl 已持久化 ($conf)"

    local applied=false svc
    for svc in sing-box sb xr; do
        if [ -f "/etc/systemd/system/${svc}.service" ]; then
            mkdir -p "/etc/systemd/system/${svc}.service.d" 2>/dev/null || continue
            atomic_write "/etc/systemd/system/${svc}.service.d/99-vpnplus.conf" <<'LIMIT'
[Service]
LimitNOFILE=1048576
LIMIT
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
