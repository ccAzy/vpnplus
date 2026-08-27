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
    if command -v sb &>/dev/null && [ -f /etc/s-box/sb.json ]; then
        ok "sing-box-yg 已安装，跳过"; return 0
    fi
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


