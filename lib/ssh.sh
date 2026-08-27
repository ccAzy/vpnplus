#!/bin/bash
# lib/ssh.sh — SSH 密钥加固（仅密钥登录，禁用密码）
[ -n "${VPNPLUS_SSH_LOADED:-}" ] && return 0
VPNPLUS_SSH_LOADED=1

# ensure_ssh_keyonly — 幂等：关闭密码登录，仅保留密钥
# 处理 /etc/ssh/sshd_config 与 /usr/local/etc/sshd_config（若存在）
# 去重后追加干净块，避免重复叠加
ensure_ssh_keyonly() {
    if ${DRY_RUN:-false}; then
        info "[dry-run] 将加固 SSH 为仅密钥登录（PasswordAuthentication no）"
        return 0
    fi
    local changed=false
    for cfg in /etc/ssh/sshd_config /usr/local/etc/sshd_config; do
        [ -f "$cfg" ] || continue
        # 校验是否已是期望状态
        if grep -qE "^PasswordAuthentication no" "$cfg" 2>/dev/null && \
           grep -qE "^PubkeyAuthentication yes" "$cfg" 2>/dev/null && \
           grep -qE "^PermitRootLogin prohibit-password" "$cfg" 2>/dev/null; then
            info "SSH 已是密钥-only ($cfg)，跳过"
            continue
        fi
        info "加固 SSH 仅密钥登录 ($cfg)..."
        cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        # 去除旧的冲突行（大小写不敏感，保留注释外的有效指令）
        grep -vE "^\s*#?\s*(PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication|PubkeyAuthentication|PermitRootLogin)" "$cfg" > /tmp/sshd.clean 2>/dev/null || true
        cat /tmp/sshd.clean > "$cfg" 2>/dev/null || return 1
        cat >> "$cfg" <<'HARDEN'

# === vpnplus hardening: key-only ===
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
HARDEN
        # 校验语法
        local sshd_bin="/usr/sbin/sshd"
        [ -x /usr/local/sbin/sshd ] && sshd_bin="/usr/local/sbin/sshd"
        # 对应 cfg 用对应二进制校验
        if [[ "$cfg" == /usr/local* ]]; then sshd_bin="/usr/local/sbin/sshd"; fi
        if "$sshd_bin" -t -f "$cfg" 2>&1 | grep -q "Unsupported option UsePAM"; then
            # 新版 sshd 编译时无 PAM，移除 UsePAM 行避免警告
            sed -i '/^\s*UsePAM/d' "$cfg" 2>/dev/null || true
            "$sshd_bin" -t -f "$cfg" 2>/dev/null || warn "sshd -t 校验仍有警告 ($cfg)，但不影响密钥登录"
        fi
        if ! "$sshd_bin" -t -f "$cfg" 2>/dev/null; then
            warn "sshd 配置校验失败 ($cfg)，已备份，跳过重启"
            continue
        fi
        changed=true
        ok "SSH 配置已更新 ($cfg)"
    done
    if $changed; then
        # 重启 sshd（兼容 ssh/sshd 两种服务名）
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null; then
            sleep 1
            ok "SSH 服务已重启，密码登录已关闭"
        else
            warn "SSH 重启失败，请手动: systemctl restart ssh"
        fi
        # 二次验证
        if sshd -T -f /etc/ssh/sshd_config 2>/dev/null | grep -qi "^passwordauthentication no"; then
            ok "验证通过: PasswordAuthentication no"
        else
            warn "验证未通过，sshd -T 仍显示 yes，请检查 /etc/ssh/sshd_config 是否被 Include 覆盖"
        fi
    fi
}
