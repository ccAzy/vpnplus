#!/bin/bash
# lib/singbox.sh — sing-box 安装与投喂
[ -n "${VPNPLUS_SINGBOX_LOADED:-}" ] && return 0
VPNPLUS_SINGBOX_LOADED=1

sb_feed() {  # sb_feed <超时秒数> - <<'KEYS'  ... KB: 用 stdin 传入按键
    local secs="${1:-120}"; shift
    local out _before _after _pid _new_pids=""
    # 记录本函数开始前已有的 sb 进程，只杀本次新产生的孤儿（不误伤同机其他 sb 会话）
    _before=$(pgrep -f 'bash /usr/bin/sb' 2>/dev/null | sort -n | tr '\n' ' ' || true)
    out=$(timeout "$secs" sb "$@" 2>&1 || true) || true
    _after=$(pgrep -f 'bash /usr/bin/sb' 2>/dev/null | sort -n | tr '\n' ' ' || true)
    for _pid in $_after; do
        case " $_before " in *" $_pid "*) ;; *) _new_pids="$_new_pids $_pid";; esac
    done
    [ -n "$_new_pids" ] && { for _pid in $_new_pids; do kill -9 "$_pid" 2>/dev/null || true; done; }
    # 输出追加进诊断日志（去色），失败时便于回溯 sb 到底做了什么/卡在哪
    if [ -n "$out" ]; then
        echo "──[sb_feed t=${secs}] $(date -Is)" >> /var/log/vpnplus-sbfeed.log 2>/dev/null || true
        printf '%s\n' "$out" | sed -E 's/\x1B\[[0-9;]*[mK]//g' >> /var/log/vpnplus-sbfeed.log 2>/dev/null || true
    fi
    printf '%s' "$out"
}



install_singbox_yg() {
    if ! ${FORCE:-false} && command -v sb &>/dev/null && [ -f /etc/s-box/sb.json ]; then
        ok "sing-box-yg 已安装，跳过（--force 覆盖）"; return 0
    fi
    if ${FORCE:-false} && command -v sb &>/dev/null; then info "--force 已启用，强制重装 sing-box-yg"; fi
    if ! command -v sb &>/dev/null; then
        info "下载 sing-box-yg 管理脚本（锁定 commit ${SB_COMMIT:0:8}）..."
        local tmp="/tmp/sb.sh.download"
        if ! run curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp" "$SB_URL" || [ ! -s "$tmp" ]; then
            fail "sb.sh 下载失败（URL: $SB_URL）"; rm -f "$tmp" 2>/dev/null || true; return 1
        fi
        local actual
        actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)
        if [ "$actual" != "$SB_SHA256" ]; then
            fail "sb.sh SHA256 校验失败（期望 ${SB_SHA256:0:12}... 实得 ${actual:-空}）—— 中止，防供应链篡改"
            rm -f "$tmp" 2>/dev/null || true; return 1
        fi
        ok "sb.sh SHA256 校验通过"
        run install -m 0755 "$tmp" /usr/bin/sb
        manifest "sb.sh installed commit=${SB_COMMIT} sha256=$actual"
        rm -f "$tmp" 2>/dev/null || true
        [ -s /usr/bin/sb ] || { fail "/usr/bin/sb 写入失败"; return 1; }
        ok "sing-box-yg 管理脚本已安装（commit ${SB_COMMIT:0:8}）"
    else
        # 重跑复查：即使 sb 已存在，也校验其哈希是否落在可信集合内（原版 或 Argo 补丁版白名单）。
        # 防：首次校验只保证下载时刻安全，重跑时 /usr/bin/sb 可能已被替换/被 sed 补丁过而失去 pin 意义。
        local cur_sha patched_ok=false
        cur_sha=$(sha256sum /usr/bin/sb 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$cur_sha" ] && [ "$cur_sha" = "$SB_SHA256" ]; then
            ok "sing-box-yg 哈希与原版一致，保持"
        elif [ -f "$SB_PATCH_MARKER" ] && [ "$cur_sha" = "$(cat "$SB_PATCH_MARKER" 2>/dev/null || true)" ]; then
            ok "sing-box-yg 哈希命中补丁白名单（Argo http2→auto 已打）"; patched_ok=true
        else
            warn "现有 /usr/bin/sb 哈希不在可信集合（原版/补丁版），重新下载覆盖..."
            local tmp="/tmp/sb.sh.download"
            if ! run curl -fsSL --connect-timeout 15 --max-time 120 -o "$tmp" "$SB_URL" || [ ! -s "$tmp" ]; then
                fail "sb.sh 重新下载失败（URL: $SB_URL）"; rm -f "$tmp" 2>/dev/null || true; return 1
            fi
            local actual
            actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || true)
            if [ "$actual" != "$SB_SHA256" ]; then
                fail "sb.sh 重新下载后 SHA256 仍不匹配（期望 ${SB_SHA256:0:12}... 实得 ${actual:-空}）—— 中止，防供应链篡改"
                rm -f "$tmp" 2>/dev/null || true; return 1
            fi
            run install -m 0755 "$tmp" /usr/bin/sb
            manifest "sb.sh re-installed (hash drift) commit=${SB_COMMIT} sha256=$actual"
            rm -f "$tmp" 2>/dev/null || true
            [ -s /usr/bin/sb ] || { fail "/usr/bin/sb 写入失败"; return 1; }
            cur_sha="$actual"; patched_ok=false
            ok "sing-box-yg 已重新下载并校验"
        fi
        ok "sing-box-yg 管理脚本已就绪 (sha=${cur_sha:0:12})"
    fi
    sleep 1

    [ -f /etc/s-box/sb.json ] && { ok "sing-box 已安装，跳过"; return 0; }
    systemctl is-active sb >/dev/null 2>&1 && { ok "sing-box 服务运行中"; return 0; }
    systemctl is-active xr >/dev/null 2>&1 && { ok "xray 服务运行中"; return 0; }

    info "自动安装 sing-box（全默认配置，全程无需操作）..."
    sleep 2
    run rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb.service /etc/systemd/system/xr.service
    run systemctl daemon-reload || true
    # 安装流程: 1 → ''(开放端口) → ''(最新内核) → ''(自签) → ''(随机端口) → ''(不共用)
    if ! $DRY_RUN; then
        printf '1\n\n\n\n\n0\n0\n0\n' | sb_feed 300 || { warn "sb 安装菜单执行异常"; }
    else
        info "[dry-run] printf '1\\n\\n\\n\\n\\n' | timeout 300 sb"
    fi

    if [ -f /etc/s-box/sb.json ]; then ok "sing-box 安装完成"; return 0; fi
    if systemctl is-active sb >/dev/null 2>&1 || systemctl is-active xr >/dev/null 2>&1; then
        ok "sing-box 已运行（检测到服务）"; return 0
    fi
    fail "sing-box 未能自动完成安装"; info "修复后重试: bash deploy_singbox.sh"
    return 1
}



assert_sb_menu() {
        [ -x /usr/bin/sb ] || return 0
        local banner
        banner=$(printf '0\n0\n' | timeout 10 bash /usr/bin/sb 2>&1 | sed -E 's/\x1B\[[0-9;]*[mK]//g' || true)
        # 预期：部署脚本注释锁定的是 v2x 系列（sing-box-yg）。抓到版本号便于人工对表；
        # 抓不到也继续（可能 sb 启动即进子菜单），但记录到日志供排查。
        local ver
        ver=$(printf '%s' "$banner" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
        if [ -n "$ver" ]; then
            info "sb 版本指纹: $ver（脚本投喂序列按锁定 SB_COMMIT 编写）"
            if ! printf '%s' "$ver" | grep -qE '^v2'; then
                warn "sb 版本 $ver 不是脚本预期的 v2x 系列，菜单序号可能漂移；若后续步骤失败请核对 SB_COMMIT/SB_SHA256 并检查 /var/log/vpnplus-sbfeed.log"
            fi
        else
            info "[sb] 未从横幅识别到版本号，继续（依赖 SB_SHA256 锁定的菜单结构）"
        fi
        manifest "sb banner probe ver=${ver:-none}"
        return 0
    }


apply_argo_patch() {
    [ -f /usr/bin/sb ] || { warn "sb.sh 不存在，跳过 Argo 协议补丁"; return 1; }
    if grep -q -- '--protocol http2' /usr/bin/sb; then
        run sed -i 's/--protocol http2/--protocol auto/g' /usr/bin/sb
        if grep -q -- '--protocol auto' /usr/bin/sb && ! grep -q -- '--protocol http2' /usr/bin/sb; then
            ok "Argo 传输协议已优化: http2 → auto (QUIC 优先，自动回退)"
            # 记录补丁后的哈希到白名单标记，供重跑复查 /usr/bin/sb 时命中（见 install_singbox_yg）
            if ! $DRY_RUN; then
                sha256sum /usr/bin/sb 2>/dev/null | awk '{print $1}' > "$SB_PATCH_MARKER" 2>/dev/null || true
                manifest "argo patch applied; sb patched sha256 recorded"
            fi
        else
            warn "Argo 协议补丁未完全生效，请检查 /usr/bin/sb"
        fi
    else
        info "Argo 已是 auto 协议，跳过补丁"
    fi
    if pgrep -f 'cloudflared.*--protocol http2' >/dev/null 2>&1; then
        warn "检测到旧 http2 Argo 进程，下次重启 Argo 时生效"
    fi
    return 0
}

# ── IPv4 入口切换（SB 15-1）+ 出口校验（只读告警，不动库）──
# 入口IP（订阅 server:）走 SB 15-1：sb 管理 server_ip.log，最稳；出口 strategy 1.13 已无 SB 菜单，
# 若直接 jq 强写易 FATAL，故 deploy 仅切入口，出口由 verify 只读告警，手动 15-1 + --force 重跑兜底
force_ipv4_lock() {
    info "切换入口IP为 IPv4（SB 15-1）..."
    if [ ! -f /etc/s-box/sb.json ]; then warn "sb.json 不存在，跳过"; return 0; fi
    if ${DRY_RUN:-false}; then info "[dry-run] 将执行 SB 15-1 切换入口为 IPv4"; return 0; fi
    if declare -F ensure_singbox_legacy_env >/dev/null 2>&1; then ensure_singbox_legacy_env || true; fi
    # SB 15-1：刷新本地IP并选 IPv4 输出（回车默认即 IPv4）
    if command -v sb >/dev/null 2>&1; then
        printf "15\n1\n" | sb_feed 30 2>&1 | tail -n 5 || true
        sleep 2
        local cur_ip
        cur_ip=$(cat /etc/s-box/server_ip.log 2>/dev/null || true)
        if echo "$cur_ip" | grep -q "^[0-9]"; then ok "入口IP已切 IPv4 ($cur_ip)"; else warn "入口IP仍非 IPv4 ($cur_ip)，请手动 sb→15→1"; fi
    else
        warn "sb 不存在，跳过入口切换"
    fi
    # 出口校验：1.13 无 SB 菜单，仅 --force 时才动库（带备份校验），平时只告警
    local bad
    bad=$(jq -r '.route.rules[]? | select(.strategy != null and .strategy != "ipv4_only") | .strategy' /etc/s-box/sb.json 2>/dev/null | head -1 || true)
    bad+=$(jq -r '.outbounds[]? | select((.type=="direct" or .type=="socks") and .domain_strategy != "ipv4_only") | .domain_strategy // "null"' /etc/s-box/sb.json 2>&1 | head -1 || true)
    if [ -n "$bad" ]; then
        if ${FORCE:-false}; then
            info "出口非 ipv4_only ($bad)，--force 下尝试修复..."
            cp /etc/s-box/sb.json /etc/s-box/sb.json.bak.ipv4 2>/dev/null || true
            if jq '(.route.rules[]? | select(.strategy != null) | .strategy) = "ipv4_only" | (.dns.strategy? | select(. != null)) = "ipv4_only" | (.dns.servers[]? | select(.strategy != null) | .strategy) = "ipv4_only" | (.outbounds[]? | select(.type=="direct" or .type=="socks") | .domain_strategy) = "ipv4_only"' /etc/s-box/sb.json > /tmp/sb.json.tmp 2>/dev/null && [ -s /tmp/sb.json.tmp ] && ! cmp -s /etc/s-box/sb.json /tmp/sb.json.tmp 2>/dev/null; then
                cat /tmp/sb.json.tmp > /etc/s-box/sb.json && rm -f /tmp/sb.json.tmp
                jq empty /etc/s-box/sb.json 2>/dev/null && systemctl try-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true; sleep 2
                ok "出口已切 ipv4_only"
            else rm -f /tmp/sb.json.tmp 2>/dev/null || true; warn "出口修复失败，保持原状"; fi
        else warn "出口仍非 ipv4_only ($bad)，建议 bash deploy_singbox.sh --force 重跑"; fi
    else ok "出口已是 ipv4_only"; fi
}

# sing-box 1.12+ legacy domain_strategy 兼容：必须注入环境变量否则 FATAL
ensure_singbox_legacy_env() {
    local dropin="/etc/systemd/system/sing-box.service.d/99-vpnplus.conf"
    local need_restart=false
    # 确保 drop-in 存在且包含 Environment
    if [ ! -f "$dropin" ] || ! grep -q "ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" "$dropin" 2>/dev/null; then
        if ${DRY_RUN:-false}; then
            info "[dry-run] 将写入 $dropin: Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true"
            return 0
        fi
        mkdir -p "$(dirname "$dropin")" 2>/dev/null || true
        # 保留原有 LimitNOFILE，若不存在则新建
        if [ -f "$dropin" ]; then
            grep -q "LimitNOFILE" "$dropin" 2>/dev/null || echo "LimitNOFILE=1048576" >> "$dropin"
        else
            cat > "$dropin" <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
        fi
        if ! grep -q "ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS" "$dropin" 2>/dev/null; then
            echo "Environment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true" >> "$dropin"
            ok "已注入 sing-box 兼容环境变量 ($dropin)"
            need_restart=true
        fi
        # 兼容 sb/xr 服务也注入（若存在）
        for svc in sb xr; do
            if [ -f "/etc/systemd/system/${svc}.service" ]; then
                local d="/etc/systemd/system/${svc}.service.d/99-vpnplus.conf"
                mkdir -p "$(dirname "$d")" 2>/dev/null || true
                grep -q "ENABLE_DEPRECATED" "$d" 2>/dev/null || echo -e "[Service]\nEnvironment=ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true" > "$d"
            fi
        done
        systemctl daemon-reload 2>/dev/null || true
        # 若当前 sing-box 正在运行，重启以生效
        if systemctl is-active sing-box >/dev/null 2>&1; then
            systemctl try-restart sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
            sleep 2
            need_restart=false
        fi
    fi
    # 额外校验：若仍在 crash loop，强制重启一次
    if systemctl is-failed sing-box >/dev/null 2>&1; then
        warn "检测到 sing-box 失败状态，尝试重启"
        systemctl restart sing-box 2>/dev/null || true
        sleep 2
    fi
    if systemctl is-active sing-box >/dev/null 2>&1; then
        ok "sing-box 运行正常（legacy env 已生效）"
    else
        warn "sing-box 仍未运行，请检查 journalctl -u sing-box"
    fi
}


