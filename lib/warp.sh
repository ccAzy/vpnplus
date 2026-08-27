#!/bin/bash
# lib/warp.sh — WARP 与分流
[ -n "${VPNPLUS_WARP_LOADED:-}" ] && return 0
VPNPLUS_WARP_LOADED=1

setup_warp() {
    info "清理旧 WARP 残留..."
    run pkill -9 -f sbwpph 2>/dev/null || true
    run rm -f /etc/s-box/sbwpph /etc/s-box/sbwpph.log
    run sed -i '/sbwpph/d' /etc/s-box/sb.json 2>/dev/null || true

    info "安装 WARP-plus-Socks5 代理..."
    if ! $DRY_RUN; then
        sb_feed 120 <<-EOSUB || true
14
1

0
0
0
0
EOSUB
    else
        info "[dry-run] sb 菜单 14-1 安装 WARP"
    fi
    if [ -f /etc/s-box/sbwpph ] && pgrep -f sbwpph >/dev/null; then ok "WARP-plus-Socks5 已安装并运行"
    elif [ -f /etc/s-box/sbwpph ]; then warn "WARP 文件存在但进程未运行，尝试: sb → 14 → 1"
    else warn "WARP 安装失败（不影响核心代理功能，域名分流不可用）"; fi
}



setup_domain_routing() {
    if [ ! -f /etc/s-box/sbwpph ] || ! pgrep -f sbwpph >/dev/null; then
        warn "WARP 未运行，跳过域名分流"; return 0
    fi
    info "配置域名分流（WARP-socks5-ipv4 优先）..."
    if ! $DRY_RUN; then
        sb_feed 120 <<-EOSUB || true
5
3
1
openai.com chatgpt.com oaistatic.com aistatic.com claude.ai anthropic.com gemini.google.com perplexity.ai huggingface.co netflix.com nflxvideo.net youtube.com ytimg.com googlevideo.com google.com googleapis.com gstatic.com bing.com twitter.com x.com
0
0
0
0
EOSUB
    else
        info "[dry-run] sb 菜单 5-3-1 域名分流"
    fi
    local CHECK
    CHECK=$(grep -c 'openai.com' /etc/s-box/sb.json 2>/dev/null || true)
    if [ "${CHECK:-0}" -gt 0 ]; then ok "域名分流已配置，AI + 流媒体 + 搜索引擎走 WARP"
    else warn "分流配置可能未完全生效，可稍后手动 sb → 5 检查"; fi
}



fix_mport_dup() {
    # sb 的 hy2 mport 来源是: iptables -t nat -nL | grep hy2_port | awk '{print $8}'
    # 若 PREROUTING 残留 + ACVPN_PORTHOP 各有一条 DNAT，sb 会拼成 "40000-42000,40000-42000"。
    # 这里做幂等去重：对 hy2.txt / jhsub.txt / websbox 副本的 mport= 去重逗号段。
    local changed=false f
    for f in /etc/s-box/hy2.txt /etc/s-box/jhsub.txt; do
        [ -f "$f" ] || continue
        # 仅当出现重复逗号段时处理
        if grep -q 'mport=' "$f" 2>/dev/null && grep -q 'mport=.*,' "$f" 2>/dev/null; then
            local tmp
            tmp=$(mktemp /tmp/vpnplus-mport.XXXXXX)
            # 逐行：把 mport= 后的逗号列表去重（保留首次出现顺序）
            python3 - "$f" "$tmp" <<'PY' 2>/dev/null || true
import sys, re
src, dst = sys.argv[1], sys.argv[2]
def dedup_line(line):
    m = re.search(r'mport=([^&\s]+)', line)
    if not m:
        return line
    raw = m.group(1)
    parts = raw.split(',')
    seen=set(); uniq=[]
    for p in parts:
        p=p.strip()
        if p and p not in seen:
            seen.add(p); uniq.append(p)
    fixed=','.join(uniq)
    return line.replace(raw, fixed, 1) if fixed != raw else line
with open(src, encoding='utf-8', errors='ignore') as s, open(dst,'w', encoding='utf-8') as d:
    for ln in s:
        d.write(dedup_line(ln))
PY
            if [ -s "$tmp" ] && ! cmp -s "$f" "$tmp" 2>/dev/null; then
                cat "$tmp" > "$f" 2>/dev/null && changed=true
            fi
            rm -f "$tmp" 2>/dev/null || true
            # python3 不可用/失败时的兜底：仅修已知双写
            if grep -q 'mport=40000-42000,40000-42000' "$f" 2>/dev/null; then
                sed -i 's/mport=40000-42000,40000-42000/mport=40000-42000/g' "$f" 2>/dev/null && changed=true
            fi
        fi
    done
    if [ "$changed" = true ]; then
        # 同步 websbox 目录（busybox httpd 根）
        if [ -f /etc/s-box/subtoken.log ] && [ -d /root/websbox ]; then
            local tok
            tok=$(tr -cd 'a-zA-Z0-9_-' < /etc/s-box/subtoken.log 2>/dev/null || true)
            [ -n "$tok" ] && [ -d "/root/websbox/$tok" ] && {
                cp -f /etc/s-box/jhsub.txt "/root/websbox/$tok/jhsub.txt" 2>/dev/null || true
                cp -f /etc/s-box/hy2.txt "/root/websbox/$tok/hy2.txt" 2>/dev/null || true
                # 兼容旧 token 目录落在根下的情况
                cp -f /etc/s-box/jhsub.txt /root/websbox/jhsub.txt 2>/dev/null || true
            } || true
        fi
        ok "订阅 mport 重复已修复（去重后同步 websbox）"
    fi
}



setup_logrotate() {
    if $DRY_RUN; then info "[dry-run] 安装 /etc/logrotate.d/vpnplus（轮转 vpnplus 各类日志）"; return 0; fi
    cat > /etc/logrotate.d/vpnplus <<'ROT'
/var/log/vpnplus-optimize.log
/var/log/vpnplus-optimize-manifest.log
/var/log/vpnplus-singbox-manifest.log
/var/log/vpnplus-sbfeed.log
/etc/s-box/argo.log
{
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
ROT
    chmod 0644 /etc/logrotate.d/vpnplus 2>/dev/null || true
    # 若 logrotate 服务在则检查配置语法
    command -v logrotate >/dev/null 2>&1 && logrotate -d /etc/logrotate.d/vpnplus >/dev/null 2>&1 \
        && ok "日志轮转已配置 (/etc/logrotate.d/vpnplus，周轮+保留4份+压缩)" \
        || warn "logrotate 配置已写，但语法校验未通过或 logrotate 未安装（日志将不轮转）"
    return 0
}


