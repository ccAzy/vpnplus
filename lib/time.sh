#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/time.sh — 时间同步（chrony 国内源），供 deploy_* 与 verify 共用

# shellcheck disable=SC1091
[ -n "${VPNPLUS_TIME_LOADED:-}" ] && return 0
VPNPLUS_TIME_LOADED=1

# 依赖 lib/common.sh 的 info/ok/warn/manifest/run
ensure_time_sync() {
    info "校准系统时间（chrony 国内源）..."
    if ${DRY_RUN:-false}; then info "[dry-run] 将配置 chrony 并同步时间"; return 0; fi
    cat > /etc/chrony/chrony.conf <<'CHRONY'
pool ntp.aliyun.com iburst
pool ntp1.aliyun.com iburst
pool cn.pool.ntp.org iburst
pool pool.ntp.org iburst
makestep 1 3
rtcsync
CHRONY
    systemctl enable --now chrony 2>/dev/null || systemctl restart chrony 2>/dev/null || true
    timeout 15 chronyc makestep 2>/dev/null || timeout 15 ntpdate -u ntp.aliyun.com 2>/dev/null || true
    sleep 2
    if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then
        ok "时间已同步（chrony Normal）"
    else
        chronyc tracking 2>&1 | head -5 || true
        warn "chrony 尚未 Normal，稍后将自动追上（已设 makestep 1 3）"
    fi
    if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then
        ok "System clock synchronized: yes"
    else
        info "timedatectl: $(timedatectl 2>/dev/null | grep -E 'synchronized|NTP' | tr '\n' ';')"
    fi
    manifest "time sync ensured via chrony"
}

check_time_sync() {
    local _pass=0 _fail=0
    if command -v chronyc >/dev/null 2>&1; then
        if chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal'; then ok "chrony 已同步（Leap Normal）"; _pass=$((_pass+1)); else warn "chrony 未 Normal（$(chronyc tracking 2>/dev/null | grep 'Leap status' | head -1)）"; _fail=$((_fail+1)); fi
        if chronyc sources -v 2>/dev/null | grep -q '\^'; then ok "chrony 源可达"; _pass=$((_pass+1)); else warn "chrony 源不可达或未配置国内源"; _fail=$((_fail+1)); fi
    else
        warn "chrony 未安装（时间漂移会导致 bad timestamp 全不通，建议 apt install chrony）"; _fail=$((_fail+1))
    fi
    if timedatectl 2>/dev/null | grep -q 'System clock synchronized: yes'; then ok "System clock synchronized: yes"; _pass=$((_pass+1)); else warn "System clock synchronized: no（timedatectl）"; _fail=$((_fail+1)); fi
    local _off
    _off=$(timeout 5 ntpdate -q ntp.aliyun.com 2>&1 | grep -oE 'offset .* sec' | head -1 || true)
    [ -n "$_off" ] && info "NTP 偏移: $_off"
    return 0
}
