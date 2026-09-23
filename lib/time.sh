#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# lib/time.sh — 时间同步（chrony 国内源），供 deploy_* 与 verify 共用

# shellcheck disable=SC1091
[ -n "${VPNPLUS_TIME_LOADED:-}" ] && return 0
VPNPLUS_TIME_LOADED=1

# 依赖 lib/common.sh 的 info/ok/warn/manifest/run/atomic_write
ensure_time_sync() {
    info "校准系统时间（chrony 国内源）..."
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将配置 chrony 并同步时间"
        return 0
    fi
    # 双路径：Debian/Ubuntu 均为 /etc/chrony/chrony.conf；老模板/自定义为 /etc/chrony.conf
    local chrony_conf="/etc/chrony/chrony.conf"
    if [ ! -d /etc/chrony ] && [ -f /etc/chrony.conf ]; then
        chrony_conf="/etc/chrony.conf"
    fi
    # 保留用户源：旧文件中的 sourcedir/confdir/include 行回填，避免清空 DHCP 下发源
    local keep_lines=""
    if [ -f "$chrony_conf" ]; then
        keep_lines=$(grep -E '^[[:space:]]*(sourcedir|confdir|include)[[:space:]]' "$chrony_conf" 2>/dev/null | sort -u || true)
    fi
    {
        printf '%s\n' "pool ntp.aliyun.com iburst"
        printf '%s\n' "pool ntp1.aliyun.com iburst"
        printf '%s\n' "pool cn.pool.ntp.org iburst"
        printf '%s\n' "pool pool.ntp.org iburst"
        [ -n "$keep_lines" ] && printf '%s\n' "$keep_lines"
        printf '%s\n' "makestep 1 3"
        printf '%s\n' "rtcsync"
    } | atomic_write "$chrony_conf" "bak.$(date +%Y%m%d-%H%M%S)"
    # 关竞争者：systemd-timesyncd 与 chrony 双跑会抢 NTP（Ubuntu 云镜像常见），幂等关闭
    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd'; then
        run systemctl disable --now systemd-timesyncd 2>/dev/null || true
        run systemctl mask systemd-timesyncd 2>/dev/null || true
        ok "systemd-timesyncd 已停用（防与 chrony 抢 NTP）"
    fi
    systemctl enable --now chrony 2>/dev/null || systemctl restart chrony 2>/dev/null || true
    # chrony.conf 非默认路径时重载指定配置（Debian/Ubuntu 默认路径无需 -f）
    if [ "$chrony_conf" != "/etc/chrony/chrony.conf" ]; then
        info "chrony 配置位于 $chrony_conf（非默认路径），请确认 chronyd 启动参数已指向该文件"
    fi
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
    manifest "time sync ensured via chrony ($chrony_conf)"
}
