#!/bin/bash
# lib/optimize.sh — BBRv3 与网络极限优化
[ -n "${VPNPLUS_OPTIMIZE_LOADED:-}" ] && return 0
VPNPLUS_OPTIMIZE_LOADED=1

install_bbrv3() {
    if echo "$CUR_KERNEL" | grep -q "bbrv3"; then
        local cur_ver latest_tag latest_ver
        cur_ver=$(echo "$CUR_KERNEL" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
        latest_tag=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
          "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null \
          | jq -r '.[].tag_name // empty' | grep -F 'max' | head -1 || true)
        latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [ -z "$latest_ver" ]; then
            ok "已是 BBRv3: $CUR_KERNEL（无法确认最新版本，跳过）"; return 0
        elif [ "$cur_ver" = "$latest_ver" ]; then
            ok "已是最新 BBRv3: $CUR_KERNEL"; return 0
        else
            warn "当前 $CUR_KERNEL，最新 ${latest_ver}，开始升级..."
        fi
    fi

    info "获取 BBRv3 内核..."
    local TAG="" DOWNLOAD_URL="" api_json

    if [ -n "$VERSION_PIN" ]; then
        # 显式锁定版本：TAG = ${ARCH}-${VERSION}-max
        local arch_tag="$DEB_ARCH"; [ "$DEB_ARCH" = "amd64" ] && arch_tag="x86_64"
        TAG="${arch_tag}-${VERSION_PIN}-max"
        info "锁定版本: $TAG"
        api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 30 \
          "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases/tags/${TAG}" 2>/dev/null || true)
        DOWNLOAD_URL=$(echo "$api_json" | jq -r '.assets[]?.browser_download_url // empty' \
          | grep -F "linux-image-" | grep -F "joeyblog-bbrv3" | grep -F "$DEB_ARCH.deb" | head -1 || true)
    else
        # 默认：取最新 -max release
        api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
          "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null || true)
        DOWNLOAD_URL=$(echo "$api_json" | jq -r '.[].assets[]?.browser_download_url // empty' \
          | grep -F "linux-image-" | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1 || true)
    fi

    [ -z "$DOWNLOAD_URL" ] && { fail "无法获取任何可用的 BBRv3 下载地址（API 与 kernel.org 均失败）"; return 1; }

    info "下载 BBRv3... ($(basename "$DOWNLOAD_URL"))"
    if ! run curl -fL# -H "$UA" --retry 3 --retry-delay 2 --retry-connrefused --connect-timeout 15 --max-time 120 -o /tmp/bbrv3.deb "$DOWNLOAD_URL" || [ ! -s /tmp/bbrv3.deb ]; then
        fail "BBRv3 下载失败"; return 1
    fi

    # ── 强制 SHA256 校验（与旧版最大差异：失败即中止，不降级） ──
    local pkg_name sha_url expected actual
    pkg_name=$(basename "$DOWNLOAD_URL")
    sha_url="$(dirname "$DOWNLOAD_URL")/SHA256SUMS"
    info "强制 SHA256 校验: $(basename "$sha_url")"
    if ! run curl -fsSL -H "$UA" --retry 2 --retry-delay 2 --max-time 20 -o /tmp/bbrv3.sha256 "$sha_url" || [ ! -s /tmp/bbrv3.sha256 ]; then
        fail "SHA256SUMS 无法获取 —— 为安全起见中止安装（内核为最高权限组件，不接受无校验安装）"
        return 1
    fi
    expected=$(awk -v f="$pkg_name" '$2 == f || $2 == "*" f {print $1; exit}' /tmp/bbrv3.sha256 2>/dev/null || true)
    if [ -z "$expected" ]; then
        fail "SHA256SUMS 中未找到 $pkg_name —— 中止安装（版本不匹配风险）"
        return 1
    fi
    actual=$(sha256sum /tmp/bbrv3.deb 2>/dev/null | awk '{print $1}' || true)
    if [ "$expected" != "$actual" ]; then
        fail "SHA256 校验失败（下载可能损坏或被篡改）—— 中止安装"
        return 1
    fi
    ok "SHA256 校验通过 ($actual)"
    manifest "BBRv3 $pkg_name sha256=$actual url=$DOWNLOAD_URL"

    if ! run dpkg -i /tmp/bbrv3.deb; then
        run apt-get install -f -y -qq || true
        run dpkg -i /tmp/bbrv3.deb || { fail "BBRv3 安装失败"; return 1; }
    fi

    # 验证新内核文件已就位（防 dpkg 成功但未解包，重启后无法开机）
    local kernel_file
    kernel_file=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*bbrv3*' -print -quit 2>/dev/null || true)
    if [ -n "$kernel_file" ]; then
        ok "新内核文件已就位: $kernel_file"
    else
        fail "未检测到 bbrv3 内核文件，安装可能未生效，中止重启"; return 1
    fi

    # grub 菜单可见（部分 VPS 默认 timeout=0）
    if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null; then
        run sed -i 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=10/g' /etc/default/grub
        run update-grub || warn "update-grub 失败，GRUB 菜单可能未更新"
    fi
    rm -f /tmp/bbrv3.deb
    ok "BBRv3 已安装（重启后生效）"
}



apply_sysctl() {
    info "应用网络暴力优化..."
    local mem_kb mem_mb RMEM TCPMEM CONNTRACK_MAX CONNTRACK_HASH
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -ge 8192 ]; then
        RMEM="134217728"; TCPMEM="65536 262144 1048576"       # ≥8GB，页数=256MB/1GB/4GB
    elif [ "$mem_mb" -ge 2048 ]; then
        RMEM="67108864"; TCPMEM="32768 65536 131072"          # 2-8GB，页数=128MB/256MB/512MB
    else
        RMEM="16777216"; TCPMEM="16384 32768 65536"           # <2GB，页数=64MB/128MB/256MB
    fi

    if [ "$mem_mb" -ge 8192 ]; then
        CONNTRACK_MAX=1000000; CONNTRACK_HASH=262144
    elif [ "$mem_mb" -ge 2048 ]; then
        CONNTRACK_MAX=500000; CONNTRACK_HASH=131072
    else
        CONNTRACK_MAX=130000; CONNTRACK_HASH=32768
    fi

    if command -v modprobe >/dev/null 2>&1; then
        if ! run modprobe tcp_bbr; then
            warn "tcp_bbr 模块加载失败，BBR 可能不可用"
        fi
        run modprobe nf_conntrack || true
    fi
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        if ! run bash -c "printf '%s\\n' '$CONNTRACK_HASH' > /sys/module/nf_conntrack/parameters/hashsize"; then
            warn "nf_conntrack hashsize 写入失败，连接跟踪仍使用内核默认桶数"
        fi
    fi

    local conf="/etc/sysctl.d/99-vpnplus-brutal.conf"
    run bash -c "cat > '$conf' <<'SYS'
# vpnplus 网络优化（按内存分级，防 OOM；tcp_mem 单位为内存页）
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $RMEM
net.core.wmem_max = $RMEM
net.ipv4.tcp_rmem = 4096 87380 $RMEM
net.ipv4.tcp_wmem = 4096 65536 $RMEM
net.ipv4.tcp_mem = $TCPMEM
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_limit_output_bytes = 262144
net.core.netdev_max_backlog = 262144
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_local_port_range = 1024 65535
net.netfilter.nf_conntrack_max = $CONNTRACK_MAX
net.ipv4.tcp_app_win = 0
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_retrans_collapse = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_comp_sack_nr = 3
net.core.optmem_max = 204800
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.busy_read = 50
net.core.busy_poll = 50
SYS"
    if ! run sysctl --system; then
        warn "sysctl --system 执行失败，部分网络参数可能未生效"
    fi
    manifest "conntrack max=$CONNTRACK_MAX hash=$CONNTRACK_HASH"
    ok "网络参数已写入 $conf 并应用（conntrack=$CONNTRACK_MAX，按内存分级防 OOM）"
}



apply_ethtool() {
    command -v ethtool >/dev/null 2>&1 || { info "ethtool 未安装，跳过网卡深度优化"; return 0; }
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        warn "无法识别默认网卡，跳过 ethtool"; return 1
    fi
    run ethtool -G "$iface" rx 4096 tx 4096 || true
    run ethtool -K "$iface" tx-checksumming on rx-checksumming on || true
    run ethtool -K "$iface" tso on gso on gro on || true
    run ethtool -K "$iface" tx-udp-segmentation on || true
    run ethtool -C "$iface" adaptive-rx off adaptive-tx off || true
    run ethtool -C "$iface" rx-usecs 16 tx-usecs 16 || true
    ok "ethtool 深度优化完成（不支持的项已自动跳过）"
}



apply_qdisc() {
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [ -z "$iface" ]; then
        warn "无法识别默认网卡，跳过 fq 队列调度"
        return 1
    fi
    if ! run tc qdisc replace dev "$iface" root fq; then
        warn "fq 队列调度应用失败，BBR 仍会运行但节奏控制可能不理想"
        return 1
    fi
    ok "fq 队列调度已应用到 $iface"
}



boost_limits() {
    run bash -c "cat > /etc/security/limits.d/99-vpnplus.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 655360
* hard nproc 655360
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 655360
root hard nproc 655360
LIMITS"
    ok "资源限制已提升"
}



apply_rss() {
    # 多队列网络调优：所有 RX/TX 队列的 RPS/XPS + ethtool + fq 持久化。
    run bash -c "cat > /usr/local/sbin/vpnplus-net-tuning.sh <<'TUNE'
#!/bin/bash
set -u

iface=\$(ip route 2>/dev/null | awk '/default/ {print \$5; exit}')
[ -n \"\$iface\" ] || { echo '[vpnplus-net-tuning] no default interface' >&2; exit 1; }
[ -d \"/sys/class/net/\$iface\" ] || { echo \"[vpnplus-net-tuning] interface not found: \$iface\" >&2; exit 1; }

cores=\$(nproc 2>/dev/null || echo 1)
if [ \"\$cores\" -ge 64 ]; then
    cpu_mask=ffffffffffffffff
else
    cpu_mask=\$(printf '%x' \$(( (1 << cores) - 1 )))
fi
rps_flow=\$((cores * 32768))

command -v ethtool >/dev/null 2>&1 && {
    ethtool -G \"\$iface\" rx 4096 tx 4096 2>/dev/null || true
    ethtool -K \"\$iface\" tx-checksumming on rx-checksumming on 2>/dev/null || true
    ethtool -K \"\$iface\" tso on gso on gro on 2>/dev/null || true
    ethtool -K \"\$iface\" tx-udp-segmentation on 2>/dev/null || true
    ethtool -C \"\$iface\" adaptive-rx off adaptive-tx off 2>/dev/null || true
    ethtool -C \"\$iface\" rx-usecs 16 tx-usecs 16 2>/dev/null || true
}

rx_count=0
for queue in /sys/class/net/\$iface/queues/rx-*; do
    [ -d \"\$queue\" ] || continue
    printf '%s\\n' \"\$cpu_mask\" > \"\$queue/rps_cpus\" 2>/dev/null || true
    printf '%s\\n' \"\$rps_flow\" > \"\$queue/rps_flow_cnt\" 2>/dev/null || true
    rx_count=\$((rx_count + 1))
done
for queue in /sys/class/net/\$iface/queues/tx-*; do
    [ -d \"\$queue\" ] || continue
    printf '%s\\n' \"\$cpu_mask\" > \"\$queue/xps_cpus\" 2>/dev/null || true
done

tc qdisc replace dev \"\$iface\" root fq 2>/dev/null || true
if [ \"\$rx_count\" -gt 0 ]; then
    sysctl -w net.core.rps_sock_flow_entries=\$((rx_count * rps_flow)) >/dev/null 2>&1 || true
fi
echo \"[vpnplus-net-tuning] applied iface=\$iface cores=\$cores rx_queues=\$rx_count mask=\$cpu_mask\"
TUNE
chmod +x /usr/local/sbin/vpnplus-net-tuning.sh
cat > /etc/systemd/system/vpnplus-net-tuning.service <<'UNIT'
[Unit]
Description=vpnplus persistent network tuning
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/vpnplus-net-tuning.sh
[Install]
WantedBy=multi-user.target
UNIT"
    run systemctl daemon-reload || true
    if ! run systemctl enable --now vpnplus-net-tuning.service; then
        warn "网络调优 systemd 服务启用失败，重启后可能不会自动恢复网卡参数"
    fi
    ok "多队列 RPS/XPS、ethtool、fq 已配置并持久化 (vpnplus-net-tuning.service)"
}



ensure_grub_boot() {
    [ -f /boot/grub/grub.cfg ] || { warn "未找到 /boot/grub/grub.cfg，跳过默认内核校验"; return 1; }
    local entries=() target=-1 idx=0 e gd
    mapfile -t entries < <(grep -oP "menuentry '\K[^']+" /boot/grub/grub.cfg 2>/dev/null || true)
    [ "${#entries[@]}" -eq 0 ] && { warn "无法解析 grub.cfg 菜单项，跳过"; return 1; }
    for e in "${entries[@]}"; do
        if [[ "$e" == *bbrv3* ]]; then target=$idx; break; fi
        idx=$((idx + 1))
    done
    [ "$target" -lt 0 ] && { warn "grub.cfg 中未找到 BBRv3 菜单项"; return 1; }
    if [ "$target" -eq 0 ]; then ok "GRUB 默认引导项已是 BBRv3"; return 0; fi

    gd=$(grep -oP '^GRUB_DEFAULT=\K.*' /etc/default/grub 2>/dev/null | head -1 || true)
    if [ "$gd" = "saved" ]; then
        if run grub-set-default "$target"; then
            ok "GRUB_DEFAULT=saved 已设为 BBRv3 (index $target)"
        else
            warn "grub-set-default 失败"
        fi
    elif [ -z "$gd" ] || [ "$gd" = "0" ]; then
        run sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=$target/" /etc/default/grub
        run update-grub || warn "update-grub 失败，GRUB 默认项可能未保存"
        ok "GRUB_DEFAULT 已设为 $target (BBRv3)"
    else
        info "GRUB_DEFAULT=$gd，BBRv3 位于 index $target；若重启未进新内核请手动改"
    fi
}


