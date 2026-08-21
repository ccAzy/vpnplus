#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# ===================================================================
# vpnplus — sing-box 彻底清理脚本
# 清除 sing-box / cloudflared(argo) / busybox / crontab / iptables(仅ACVPN链) / nftables
# 保留 /opt/cloudflared 等永久隧道文件不受影响
#
# 安全设计（相对旧版 ACVPN 的关键改进）：
#   1. 只清理 vpnplus 自己创建的独立防火墙链（ACVPN_*），
#      绝不按 'limit: above'/'#conn' 等通用文本全局删 INPUT 链规则，
#      避免误删 fail2ban / Docker / 其他程序的安全规则。
#   2. crontab 清理用 '|| true' 包裹命令替换，杜绝 set -e 静默退出。
#   3. 清理前自动备份原始 iptables/nftables 规则到 /var/backups/vpnplus/。
#   4. 清理后逐项自检，任一失败明确列出修复命令。
#
# 用法: bash cleanup.sh [--force] [--dry-run]
# ===================================================================
set -uo pipefail

FORCE=""
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE="--force" ;;
        --dry-run) DRY_RUN=true ;;
    esac
done

BAK_DIR="/var/backups/vpnplus"
CHAIN_ANTIPROBE="ACVPN_ANTIPROBE"   # filter INPUT 子链
CHAIN_PORTHOP="ACVPN_PORTHOP"       # nat PREROUTING 子链
CHAIN_RSS="ACVPN_RSS"               # filter INPUT 子链（RSS 若曾加过）

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${GREEN}[✓]${N}   $*"; }
warn() { echo -e "${YELLOW}[!]${N}   $*"; }
die()  { echo -e "${RED}[✗]${N}   $*"; exit 1; }
info() { echo -e "${CYAN}[*]${N}   $*"; }

# dry-run 安全的执行包装：--dry-run 只打印将执行的动作，不真正执行
run() {
    if $DRY_RUN; then
        info "[dry-run] $*"
        return 0
    fi
    "$@" 2>/dev/null || true
}

echo ""
echo "========================================="
echo "  vpnplus sing-box 清理"
echo "========================================="
echo ""

if [ "$FORCE" != "--force" ]; then
    echo -e "${YELLOW}警告：将清除所有 sing-box 相关配置、进程、定时任务。${N}"
    if [ -t 0 ]; then read -p "确认继续？[y/N] " confirm; else confirm=n; fi
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "已取消"; exit 0; }
fi

# ———————— 0. 备份当前防火墙规则（清理前快照，可回滚） ————————
bak_firewall() {
    echo "--- 备份防火墙规则 ---"
    run mkdir -p "$BAK_DIR"
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    if command -v iptables-save >/dev/null 2>&1; then
        run bash -c "iptables-save > '$BAK_DIR/iptables.$stamp' 2>/dev/null"
        run bash -c "ip6tables-save > '$BAK_DIR/ip6tables.$stamp' 2>/dev/null || true"
        ok "iptables 规则已备份到 $BAK_DIR (iptables.$stamp)"
    fi
    if command -v nft >/dev/null 2>&1; then
        run bash -c "nft list ruleset > '$BAK_DIR/nftables.$stamp' 2>/dev/null || true"
    fi
}

# ———————— 仅删除 vpnplus 自己的独立链（不碰第三方规则） ————————
# 关键改进：不 grep INPUT 链全局匹配删除，只处理 ACVPN_* 命名链。
clean_chains() {
    echo "--- 清理 vpnplus 独立防火墙链 ---"
    # 1) 先从主链移除 vpnplus 的跳转规则（精确匹配 jump 到命名链，绝不误伤其他规则）
    run iptables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null
    run iptables -D INPUT -j "$CHAIN_RSS" 2>/dev/null
    run iptables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null
    # IPv6 对称
    if command -v ip6tables >/dev/null 2>&1; then
        run ip6tables -D INPUT -j "$CHAIN_ANTIPROBE" 2>/dev/null
        run ip6tables -t nat -D PREROUTING -j "$CHAIN_PORTHOP" 2>/dev/null
    fi

    # 2) flush 并删除命名链
    run iptables -F "$CHAIN_ANTIPROBE" 2>/dev/null
    run iptables -X "$CHAIN_ANTIPROBE" 2>/dev/null
    run iptables -F "$CHAIN_RSS" 2>/dev/null
    run iptables -X "$CHAIN_RSS" 2>/dev/null
    run iptables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null
    run iptables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null
    if command -v ip6tables >/dev/null 2>&1; then
        run ip6tables -F "$CHAIN_ANTIPROBE" 2>/dev/null
        run ip6tables -X "$CHAIN_ANTIPROBE" 2>/dev/null
        run ip6tables -t nat -F "$CHAIN_PORTHOP" 2>/dev/null
        run ip6tables -t nat -X "$CHAIN_PORTHOP" 2>/dev/null
    fi

    # 3) 兜底：若旧版遗留了分散的 nat 端口跳跃规则（40000:42000/43000:45000）也精确按目标端口清理，
    #    但仅匹配 vpnplus/ACVPN 特有的端口范围 DNAT，依旧不动其他规则。
    command -v iptables >/dev/null 2>&1 && {
        iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null |
          grep -E 'DNAT.*dpts:(40000:42000|43000:45000) ' |
          awk '{print $1}' | sort -rn | while read -r num; do
            run iptables -t nat -D PREROUTING "$num"
        done
    }
    ok "独立防火墙链已清理（未触碰第三方规则）"
}

# ———————— 1-5：停止服务 / 杀进程 / 清 crontab / 删 unit / 删目录 ————————
# （与 ACVPN 相同，但 crontab 处理修复了 set -e 退出问题）
stop_services() {
    echo "--- 停止服务 ---"
    for svc in sing-box cloudflared cloudflared-update acvpn-rss vpnplus-net-tuning; do
        if systemctl is-active "$svc" &>/dev/null; then
            run systemctl stop "$svc" || true; ok "已停止服务: $svc"
        fi
        if systemctl is-enabled "$svc" &>/dev/null; then
            run systemctl disable "$svc" || true; ok "已禁用服务: $svc"
        fi
    done
    if systemctl is-active cloudflared-update.timer &>/dev/null; then
        run systemctl stop cloudflared-update.timer || true
        run systemctl disable cloudflared-update.timer || true
        ok "已停止/禁用: cloudflared-update.timer"
    fi
}

kill_procs() {
    echo "--- 终止进程 ---"
    run pkill -15 -f sing-box || true
    sleep 2
    for proc in sing-box 'cloudflared.*tunnel.*url.*localhost'; do
        if pgrep -f "$proc" &>/dev/null; then
            run pkill -9 -f "$proc" || true; ok "已终止: $proc"
        fi
    done
}

# 精确停止 vpnplus 订阅端口对应的 busybox httpd，不按进程名全局杀进程。
kill_sub_httpd() {
    local port pids
    [ -f /etc/s-box/subport.log ] || return 0
    port=$(grep -oE '[0-9]{1,5}' /etc/s-box/subport.log 2>/dev/null | head -1 || true)
    [ -n "$port" ] || return 0
    pids=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | sed 's/pid=//' | sort -u || true)
    for p in $pids; do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE 'busybox[[:space:]]+httpd.*(/root/websbox|subport.log)'; then
            run kill -TERM "$p" || true
            ok "已终止 vpnplus 订阅 httpd (PID $p, 端口 $port)"
        fi
    done
}

clean_crontab() {
    echo "--- 清理 crontab（仅 vpnplus 自己的条目和明确的旧 ACVPN 兼容条目） ---"
    if crontab -l &>/dev/null; then
        BEFORE=$(crontab -l 2>/dev/null | wc -l)
        # 修复 set -e 问题：grep 无匹配时返回 1，必须 || true 防静默退出
        NEW_CRON=$(crontab -l 2>/dev/null | grep -vE 'vpnplus-argo-keepalive|acvpn-argo-keepalive|/usr/bin/sb|busybox httpd.*(/root/websbox|subport.log)' || true)
        if $DRY_RUN; then
            info "[dry-run] 过滤 crontab（移除 ${BEFORE} 行中的 sb 相关条目）"
        elif [ -z "$NEW_CRON" ]; then
            crontab -r 2>/dev/null || true; ok "crontab 已整体清空"
        else
            printf '%s\n' "$NEW_CRON" | crontab - 2>/dev/null || warn "crontab 写入失败，请手动检查 crontab -e"
        fi
        AFTER=$(crontab -l 2>/dev/null | wc -l)
        REMOVED=$((BEFORE - AFTER))
        [ $REMOVED -gt 0 ] && ok "crontab: 移除 ${REMOVED} 条 sb 相关条目" || info "crontab 无 sb 条目需清理"
    else
        info "crontab 为空"
    fi
}

rm_units() {
    echo "--- 清理 systemd units ---"
    local COUNT=0 unit
    for unit in /etc/systemd/system/sing-box.service \
                /etc/systemd/system/cloudflared.service \
                /etc/systemd/system/cloudflared-update.service \
                /etc/systemd/system/cloudflared-update.timer \
                /etc/systemd/system/acvpn-rss.service \
                /etc/systemd/system/vpnplus-net-tuning.service; do
        if [ -f "$unit" ]; then
            # 只删除明确属于 vpnplus/旧 ACVPN 的 unit；不因同名而删除其他 cloudflared 服务。
            if [ "$(basename "$unit")" = "acvpn-rss.service" ] || grep -qE '/etc/s-box|/root/websbox|vpnplus|ACVPN' "$unit" 2>/dev/null; then
                run rm -f "$unit"; COUNT=$((COUNT + 1))
            else
                warn "保留未确认归属的 unit: $unit"
            fi
        fi
    done
    run systemctl daemon-reload || true
    [ $COUNT -gt 0 ] && ok "已删除 ${COUNT} 个 vpnplus systemd unit 文件" || info "无 vpnplus unit 文件需清理"
}

rm_files() {
    echo "--- 清理文件和目录 ---"
    local COUNT=0
    for path in /etc/s-box /usr/bin/sb /root/websbox /usr/local/sbin/acvpn-argo-keepalive.sh \
                /usr/local/sbin/vpnplus-net-tuning.sh; do
        if [ -e "$path" ]; then
            run rm -rf "$path"; COUNT=$((COUNT + 1)); ok "已删除: $path"
        fi
    done
    for mark in /etc/.ACVPN-optimized /etc/.ACVPN-singbox /etc/.vpnplus-optimized /etc/.vpnplus-singbox; do
        [ -f "$mark" ] && { run rm -f "$mark"; ok "已删除标记: $mark"; }
    done
    [ $COUNT -eq 0 ] && info "无 sb 文件需清理"
}

# ———————— 6-7：sysctl / nftables 遗留清理 ————————
clean_sysctl() {
    echo "--- 清理系统已应用参数（不改动第三方配置） ---"
    # 我们只移除脚本文档明确自己写入的 sysctl.d 文件（若仍存在）
    for f in /etc/sysctl.d/99-ACVPN-security.conf /etc/sysctl.d/99-ACVPN-brutal.conf \
             /etc/sysctl.d/99-vpnplus-security.conf /etc/sysctl.d/99-vpnplus-brutal.conf; do
        [ -f "$f" ] && { run rm -f "$f"; ok "已删除 sysctl 文件: $f"; }
    done
    /etc/init.d/procps restart >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
}

clean_nft() {
    echo "--- 清理 nftables（仅 vpnplus 表） ---"
    if command -v nft >/dev/null 2>&1; then
        # 只有检测到 vpnplus/旧 ACVPN 的部署痕迹时才删除通用 sing-box 表，
        # 避免清理另一套独立 sing-box 实例。
        if [ -f /etc/.vpnplus-singbox ] || [ -f /etc/.ACVPN-singbox ] || [ -d /etc/s-box ]; then
            run nft delete table inet sing-box 2>/dev/null
            run nft delete table inet vpnplus 2>/dev/null
        else
            info "未确认 nftables sing-box 表归属，保留不动"
        fi
    fi
}

# ———————— 验证 ————————
verify_clean() {
    if $DRY_RUN; then
        info "[dry-run] 跳过清理结果验证（未执行实际删除）"
        return 0
    fi
    echo ""
    echo "========================================="
    echo "  验证清理结果"
    echo "========================================="
    local PASS=0 FAIL=0
    if ! systemctl is-active sing-box &>/dev/null && [ ! -f /etc/systemd/system/sing-box.service ]; then ok "sing-box 服务已清除"; PASS=$((PASS+1)); else warn "sing-box 服务仍存在"; FAIL=$((FAIL+1)); fi
    [ ! -d /etc/s-box ] && { ok "/etc/s-box 已删除"; PASS=$((PASS+1)); } || { warn "/etc/s-box 仍存在"; FAIL=$((FAIL+1)); }
    if iptables -L "$CHAIN_ANTIPROBE" -n >/dev/null 2>&1 || iptables -t nat -L "$CHAIN_PORTHOP" -n >/dev/null 2>&1; then
        warn "vpnplus 独立防火墙链仍存在"; FAIL=$((FAIL+1))
    else
        ok "vpnplus 独立防火墙链已清除"; PASS=$((PASS+1))
    fi
    if crontab -l 2>/dev/null | grep -qE 'vpnplus-argo-keepalive|acvpn-argo-keepalive|/usr/bin/sb|busybox httpd.*(/root/websbox|subport.log)' 2>/dev/null; then
        warn "crontab 残留 sb 条目"; FAIL=$((FAIL+1))
    else
        ok "crontab 无 sb 条目"; PASS=$((PASS+1))
    fi
    remaining=$(pgrep -fc 'sing-box|cloudflared.*tunnel.*url' 2>/dev/null || echo 0)
    if [ "$remaining" -eq 0 ]; then ok "进程已清理"; PASS=$((PASS+1)); else warn "仍有 ${remaining} 个进程"; FAIL=$((FAIL+1)); fi

    echo ""
    echo "========================================="
    echo -e "  通过: ${GREEN}${PASS}${N} / 失败: ${RED}${FAIL}${N}"
    echo "========================================="
    [ $FAIL -eq 0 ] || die "部分清理失败，请手动检查（--dry-run 为预览，未做实际清理）"
    echo -e "${GREEN}清理完成。可以开始部署。${N}"
}

bak_firewall
clean_chains
stop_services
kill_procs
kill_sub_httpd
clean_crontab
rm_units
rm_files
clean_sysctl
clean_nft
verify_clean
