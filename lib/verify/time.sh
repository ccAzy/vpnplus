#!/bin/bash
# lib/verify/time.sh — verify 侧时间检查
[ -n "${VPNPLUS_VERIFY_TIME_LOADED:-}" ] && return 0
VPNPLUS_VERIFY_TIME_LOADED=1

verify_time() {
    echo "--- 时间同步 ---"
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then ok "chrony 已同步（Leap Normal）"; else warn "chrony 未 Normal（$(chronyc tracking 2>/dev/null | grep 'Leap status' | head -1)）"; fi
        if chronyc sources -v 2>/dev/null | grep -q '\^'; then ok "chrony 源可达"; else warn "chrony 源不可达或未配置国内源"; fi
    else
        warn "chrony 未安装（时间漂移会导致 bad timestamp 全不通，建议 apt install chrony）"
    fi
    if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then ok "System clock synchronized: yes"; else warn "System clock synchronized: no（timedatectl）"; fi
    local _off
    _off=$(timeout 5 ntpdate -q ntp.aliyun.com 2>&1 | grep -oE 'offset .* sec' | head -1 || true)
    [ -n "$_off" ] && info "NTP 偏移: $_off"
}
