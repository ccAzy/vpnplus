#!/bin/bash
# lib/optimize.sh — BBRv3 与网络极限优化
[ -n "${VPNPLUS_OPTIMIZE_LOADED:-}" ] && return 0
VPNPLUS_OPTIMIZE_LOADED=1

# 原子 sysctl 补丁：整文件重写经 atomic_write 落盘（幂等可重入，并发/中断不留半文件）。
# 用法: vpnplus_sysctl_set <conf> <key> <value>  — key 不存在则追加，存在则整行替换。
if ! declare -F vpnplus_sysctl_set >/dev/null 2>&1; then
vpnplus_sysctl_set() {
    local conf="$1" key="$2" val="$3" tmp
    local esc_key esc_val
    esc_key=$(printf '%s' "$key" | sed 's/[][^$.*\\]/\\&/g')
    esc_val=$(printf '%s' "$val" | sed 's/[&\\]/\\&/g')
    tmp=$(mktemp 2>/dev/null) || return 1
    if [ -f "$conf" ]; then
        sed "s|^${esc_key}[[:space:]]*=.*|${key} = ${esc_val}|" "$conf" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
        if ! grep -qE "^${esc_key}[[:space:]]*=" "$tmp" 2>/dev/null; then
            printf '%s = %s\n' "$key" "$val" >>"$tmp"
        fi
    else
        printf '%s = %s\n' "$key" "$val" >"$tmp"
    fi
    atomic_place "$tmp" "$conf" "bak"
}
fi

# GRUB 文件备份+重载：备份到 $BAK_DIR（默认 /var/backups/vpnplus），优先 update-grub，回退 grub-mkconfig。
# Debian/Ubuntu 双适配：两发行版均有 update-grub（Ubuntu 必备，Debian 装 grub-pc 即有），
# 回退路径 grub-mkconfig -o /boot/grub/grub.cfg 两边一致可用。
if ! declare -F vpnplus_grub_backup >/dev/null 2>&1; then
vpnplus_grub_backup() {
    local bakdir="${BAK_DIR:-/var/backups/vpnplus}/grub-$(date +%Y%m%d)"
    run mkdir -p "$bakdir" 2>/dev/null || true
    run cp -a /etc/default/grub "$bakdir/grub" 2>/dev/null || true
}
fi
if ! declare -F vpnplus_grub_update >/dev/null 2>&1; then
vpnplus_grub_update() {
    if run update-grub 2>/dev/null; then
        return 0
    fi
    warn "update-grub 不可用/失败，回退 grub-mkconfig -o /boot/grub/grub.cfg"
    run grub-mkconfig -o /boot/grub/grub.cfg || {
        warn "grub-mkconfig 亦失败，GRUB 更改仅在 /etc/default/grub，下次 update-grub 生效"
        return 1
    }
}
fi

install_bbrv3() {
    if echo "$CUR_KERNEL" | grep -q "bbrv3"; then
        local cur_ver latest_tag latest_ver
        cur_ver=$(echo "$CUR_KERNEL" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
        latest_tag=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
            "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null |
            jq -r '.[].tag_name // empty' | grep -F 'max' | head -1 || true)
        latest_ver=$(echo "$latest_tag" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [ -z "$latest_ver" ]; then
            ok "已是 BBRv3: $CUR_KERNEL（无法确认最新版本，跳过）"
            return 0
        elif [ "$cur_ver" = "$latest_ver" ]; then
            ok "已是最新 BBRv3: $CUR_KERNEL"
            return 0
        else
            warn "当前 $CUR_KERNEL，最新 ${latest_ver}，开始升级..."
        fi
    fi

    # 已装好、只差重启：直接跳过下载。否则会白下 141MB（2026-09-23 实测约 3 分钟）。
    local _installed_kernel="" _k
    for _k in /boot/vmlinuz-*bbrv3*; do
        [ -e "$_k" ] && {
            _installed_kernel="$_k"
            break
        }
    done
    if [ -n "$_installed_kernel" ]; then
        ok "BBRv3 内核已安装（$_installed_kernel），只差重启生效 —— 跳过下载"
        return 0
    fi

    info "获取 BBRv3 内核..."
    local TAG="" DOWNLOAD_URL="" api_json

    if [ -n "$VERSION_PIN" ]; then
        # 显式锁定版本：TAG = ${ARCH}-${VERSION}-max
        local arch_tag="$DEB_ARCH"
        [ "$DEB_ARCH" = "amd64" ] && arch_tag="x86_64"
        TAG="${arch_tag}-${VERSION_PIN}-max"
        info "锁定版本: $TAG"
        api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 30 \
            "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases/tags/${TAG}" 2>/dev/null || true)
        DOWNLOAD_URL=$(echo "$api_json" | jq -r '.assets[]?.browser_download_url // empty' |
            grep -F "linux-image-" | grep -F "joeyblog-bbrv3" | grep -F "$DEB_ARCH.deb" | head -1 || true)
    else
        # 默认：取最新 -max release
        api_json=$(curl -fsL -H "$UA" --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 20 \
            "https://api.github.com/repos/ccAzy/Actions-bbr-v3/releases?per_page=10" 2>/dev/null || true)
        DOWNLOAD_URL=$(echo "$api_json" | jq -r '.[].assets[]?.browser_download_url // empty' |
            grep -F "linux-image-" | grep -F "joeyblog-bbrv3-max" | grep -F "$DEB_ARCH.deb" | head -1 || true)
    fi

    [ -z "$DOWNLOAD_URL" ] && {
        fail "无法获取任何可用的 BBRv3 下载地址（API 与 kernel.org 均失败）"
        return 1
    }

    info "下载 BBRv3... ($(basename "$DOWNLOAD_URL"))"
    # 断点续传 + 停滞判定：固定 --max-time 在慢速链路必然失败（141MB@0.84MB/s 需 161s > 120s），
    # 且不带 -C - 的 --retry 会丢弃已下载字节重下（curl 的 "Throwing away N bytes"）。
    local _want _sz _i=0
    _want=$(curl -fsSLI -H "$UA" --connect-timeout 15 --max-time 30 "$DOWNLOAD_URL" 2>/dev/null |
        awk 'tolower($0) ~ /^content-length:/ {gsub(/[^0-9]/, "", $2); print $2}' | tail -1 || true)
    while [ "$_i" -lt 20 ]; do
        _i=$((_i + 1))
        # 上一次异常退出可能把文件写超（旧版带 --retry 的副作用）→ 删掉重下
        if [ -n "$_want" ] && [ "$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)" -gt "$_want" ]; then
            warn "本地 deb 比远端大（$(stat -c%s /tmp/bbrv3.deb)B > ${_want}B），删除重下"
            rm -f /tmp/bbrv3.deb
        fi
        # 刻意不加 --retry：curl 内部重试不重算续传偏移，会把数据从旧偏移再写一遍
        # → 文件写重/写坏。重试一律交给外层 while（每次重读文件大小、重算 Range）。
        if curl -fL# -H "$UA" -C - --connect-timeout 15 \
            --speed-limit 10240 --speed-time 60 -o /tmp/bbrv3.deb "$DOWNLOAD_URL"; then
            break
        fi
        _sz=$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)
        if [ -n "$_want" ] && [ "$_sz" = "$_want" ]; then break; fi
        warn "下载中断（已得 ${_sz}B${_want:+ / ${_want}B}），续传重试 ${_i}/20…"
        sleep 3
    done
    _sz=$(stat -c%s /tmp/bbrv3.deb 2>/dev/null || echo 0)
    if [ -n "$_want" ] && [ "$_sz" != "$_want" ]; then
        fail "BBRv3 下载不完整：${_sz}B / ${_want}B"
        return 1
    fi
    if [ "$_sz" -eq 0 ]; then
        fail "BBRv3 下载失败"
        return 1
    fi

    # ── 校验和：尽力而为，绝不阻断 ──
    # 上游（byJoey/Actions-bbr-v3 → ccAzy fork）都不产出 SHA256SUMS。
    # 原先把它设为强制 → 必然中止、内核永远装不上。2026-09-23 拍板：默认信任上游，
    # 降级为「有就比对、没有或对不上只告警」，不阻断安装，也不需要任何人维护哈希。
    local pkg_name sha_url expected actual
    pkg_name=$(basename "$DOWNLOAD_URL")
    sha_url="$(dirname "$DOWNLOAD_URL")/SHA256SUMS"
    actual=$(sha256sum /tmp/bbrv3.deb 2>/dev/null | awk '{print $1}' || true)
    if curl -fsSL -H "$UA" --retry 1 --max-time 15 -o /tmp/bbrv3.sha256 "$sha_url" 2>/dev/null && [ -s /tmp/bbrv3.sha256 ]; then
        expected=$(awk -v f="$pkg_name" '$2 == f || $2 == "*" f {print $1; exit}' /tmp/bbrv3.sha256 2>/dev/null || true)
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            ok "SHA256 校验通过 ($actual)"
        else
            warn "SHA256 未通过比对（expected=${expected:-无} actual=${actual:-无}）—— 按既定策略继续安装"
        fi
    else
        warn "上游未提供 SHA256SUMS（已知情况）—— 跳过校验，继续安装"
    fi
    manifest "BBRv3 $pkg_name sha256=${actual:-unknown} url=$DOWNLOAD_URL"

    if ! run dpkg -i /tmp/bbrv3.deb; then
        run apt-get install -f -y -qq || true
        run dpkg -i /tmp/bbrv3.deb || {
            fail "BBRv3 安装失败"
            return 1
        }
    fi

    # 验证新内核文件已就位（防 dpkg 成功但未解包，重启后无法开机）
    local kernel_file
    kernel_file=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*bbrv3*' -print -quit 2>/dev/null || true)
    if [ -n "$kernel_file" ]; then
        ok "新内核文件已就位: $kernel_file"
    else
        fail "未检测到 bbrv3 内核文件，安装可能未生效，中止重启"
        return 1
    fi

    # grub 菜单可见（部分 VPS 默认 timeout=0；Ubuntu 默认 TIMEOUT_STYLE=hidden，timeout 再大也不显示菜单）
    if grep -q '^GRUB_TIMEOUT=0' /etc/default/grub 2>/dev/null || grep -q '^GRUB_TIMEOUT_STYLE=hidden' /etc/default/grub 2>/dev/null; then
        vpnplus_grub_backup || true
        if grep -q '^GRUB_TIMEOUT=' /etc/default/grub 2>/dev/null; then
            run sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
        else
            run bash -c 'printf "%s\n" "GRUB_TIMEOUT=10" >> /etc/default/grub'
        fi
        if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub 2>/dev/null; then
            run sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
        else
            run bash -c 'printf "%s\n" "GRUB_TIMEOUT_STYLE=menu" >> /etc/default/grub'
        fi
        vpnplus_grub_update || warn "GRUB 菜单可能未更新（已备份，见 \$BAK_DIR/grub-*）"
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
        RMEM="134217728"
        TCPMEM="65536 262144 1048576" # ≥8GB，页数=256MB/1GB/4GB
    elif [ "$mem_mb" -ge 2048 ]; then
        RMEM="67108864"
        TCPMEM="32768 65536 131072" # 2-8GB，页数=128MB/256MB/512MB
    else
        RMEM="16777216"
        TCPMEM="16384 32768 65536" # <2GB，页数=64MB/128MB/256MB
    fi

    if [ "$mem_mb" -ge 8192 ]; then
        CONNTRACK_MAX=1000000
        CONNTRACK_HASH=262144
    elif [ "$mem_mb" -ge 2048 ]; then
        CONNTRACK_MAX=500000
        CONNTRACK_HASH=131072
    else
        CONNTRACK_MAX=130000
        CONNTRACK_HASH=32768
    fi

    if command -v modprobe >/dev/null 2>&1; then
        if ! run modprobe tcp_bbr; then
            warn "tcp_bbr 模块加载失败，BBR 可能不可用"
        fi
        run modprobe nf_conntrack || true
    fi
    # 开机也要有 nf_conntrack：否则 /etc/sysctl.d 里那行 nf_conntrack_max 在 boot 时写不进去
    # （2026-09-23 实测：重启后 /proc/sys/net/netfilter/nf_conntrack_max 不存在，130000 丢失）。
    # 只写「真以模块形式存在」的情况：内建内核（CONFIG_NF_CONNTRACK=y）上写了会让
    # systemd-modules-load 开机报「module not found」——Debian/Ubuntu 不同内核都可能出现。
    if modinfo -n nf_conntrack >/dev/null 2>&1; then
        mkdir -p /etc/modules-load.d 2>/dev/null || true
        atomic_write /etc/modules-load.d/vpnplus-conntrack.conf <<'MODS'
# vpnplus：让 nf_conntrack 开机加载，保证 net.netfilter.nf_conntrack_max 能应用
nf_conntrack
MODS
    else
        info "nf_conntrack 为内建（非模块），无需写 modules-load.d"
    fi
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        if ! run bash -c "printf '%s\\n' '$CONNTRACK_HASH' > /sys/module/nf_conntrack/parameters/hashsize"; then
            warn "nf_conntrack hashsize 写入失败，连接跟踪仍使用内核默认桶数"
        fi
    fi

    local conf="/etc/sysctl.d/99-vpnplus-brutal.conf"
    atomic_write "$conf" <<SYS
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
SYS
    if ! run sysctl --system; then
        warn "sysctl --system 执行失败，部分网络参数可能未生效"
    fi
    manifest "conntrack max=$CONNTRACK_MAX hash=$CONNTRACK_HASH"
    # 回读校验：conntrack 是「写了不等于生效」的典型——模块没加载时 sysctl 会静默失败
    local _ck
    _ck=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
    if [ -n "$_ck" ] && [ "$_ck" = "$CONNTRACK_MAX" ]; then
        ok "网络参数已写入 $conf 并应用（conntrack=$CONNTRACK_MAX，按内存分级防 OOM）"
    else
        warn "conntrack 未生效：期望 $CONNTRACK_MAX，实得 ${_ck:-读不到}（已尝试写 /etc/modules-load.d/vpnplus-conntrack.conf，重启后应自动生效）"
    fi
}

apply_ethtool() {
    command -v ethtool >/dev/null 2>&1 || {
        info "ethtool 未安装，跳过网卡深度优化"
        return 0
    }
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}' || true)
    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        warn "无法识别默认网卡，跳过 ethtool"
        return 1
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
    atomic_write /etc/security/limits.d/99-vpnplus.conf <<'LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 655360
* hard nproc 655360
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 655360
root hard nproc 655360
LIMITS
    ok "资源限制已提升"
}

apply_rss() {
    # 多队列网络调优：所有 RX/TX 队列的 RPS/XPS + ethtool + fq 持久化。
    # 全原子写：脚本与 service 经 atomic_write 落盘（替代 run bash -c 包裹的裸 cat）。
    atomic_write /usr/local/sbin/vpnplus-net-tuning.sh <<'TUNE'
#!/bin/bash
set -u

iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
[ -n "$iface" ] || { echo '[vpnplus-net-tuning] no default interface' >&2; exit 1; }
[ -d "/sys/class/net/$iface" ] || { echo "[vpnplus-net-tuning] interface not found: $iface" >&2; exit 1; }

cores=$(nproc 2>/dev/null || echo 1)
if [ "$cores" -ge 64 ]; then
    cpu_mask=ffffffffffffffff
else
    cpu_mask=$(printf '%x' $(( (1 << cores) - 1 )))
fi
rps_flow=$((cores * 32768))

command -v ethtool >/dev/null 2>&1 && {
    ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
    ethtool -K "$iface" tx-checksumming on rx-checksumming on 2>/dev/null || true
    ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true
    ethtool -K "$iface" tx-udp-segmentation on 2>/dev/null || true
    ethtool -C "$iface" adaptive-rx off adaptive-tx off 2>/dev/null || true
    ethtool -C "$iface" rx-usecs 16 tx-usecs 16 2>/dev/null || true
}

rx_count=0
for queue in /sys/class/net/$iface/queues/rx-*; do
    [ -d "$queue" ] || continue
    printf '%s\\n' "$cpu_mask" > "$queue/rps_cpus" 2>/dev/null || true
    printf '%s\\n' "$rps_flow" > "$queue/rps_flow_cnt" 2>/dev/null || true
    rx_count=$((rx_count + 1))
done
for queue in /sys/class/net/$iface/queues/tx-*; do
    [ -d "$queue" ] || continue
    printf '%s\\n' "$cpu_mask" > "$queue/xps_cpus" 2>/dev/null || true
done

tc qdisc replace dev "$iface" root fq 2>/dev/null || true
if [ "$rx_count" -gt 0 ]; then
    sysctl -w net.core.rps_sock_flow_entries=$((rx_count * rps_flow)) >/dev/null 2>&1 || true
fi
echo "[vpnplus-net-tuning] applied iface=$iface cores=$cores rx_queues=$rx_count mask=$cpu_mask"
TUNE
    run chmod +x /usr/local/sbin/vpnplus-net-tuning.sh
    atomic_write /etc/systemd/system/vpnplus-net-tuning.service <<'UNIT'
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
UNIT
    run systemctl daemon-reload || true
    if ! run systemctl enable --now vpnplus-net-tuning.service; then
        warn "网络调优 systemd 服务启用失败，重启后可能不会自动恢复网卡参数"
    fi
    ok "多队列 RPS/XPS、ethtool、fq 已配置并持久化 (vpnplus-net-tuning.service)"
}

ensure_grub_boot() {
    [ -f /boot/grub/grub.cfg ] || {
        warn "未找到 /boot/grub/grub.cfg，跳过默认内核校验"
        return 1
    }
    # 用「子菜单>条目」的完整路径定位 BBRv3，而不是数字索引。
    # 为什么：grub.cfg 顶层既有 menuentry 也有 submenu，只数 menuentry 会把索引算错——
    # 2026-09-23 实测：脚本算出 index 1，而真实 index 1 是「Advanced options for <发行版>」
    # 子菜单（BBRv3 实际在子菜单第 0 项）——Ubuntu 与 Debian 的标题不同，但本函数是从 grub.cfg
    # 现读标题的，两个发行版都能解析。那次侬幸进对了，但装了新内核后子菜单第 0 项
    # 会变成新内核 → 引导到错内核。用标题路径则不受索引漂移影响（GRUB 手册：submenu>entry）。
    local path gd
    path=$(awk -F"'" '
        /^[[:space:]]*submenu /   { d++; st[d]=$2; next }
        /^[[:space:]]*menuentry / { if ($2 ~ /bbrv3/) { p=""; for (i=1;i<=d;i++) p=p st[i] ">"; print p $2; found=1; exit } next }
        /^\}/                     { if (d>0) d-- }
    ' /boot/grub/grub.cfg 2>/dev/null || true)

    if [ -z "$path" ]; then
        if grep -q 'vmlinuz-.*bbrv3' /boot/grub/grub.cfg 2>/dev/null; then
            warn "未解析出 BBRv3 独立菜单项（grub.cfg 里有 bbrv3 内核）；重启后用 uname -r 确认"
            return 0
        fi
        warn "grub.cfg 中未找到 BBRv3 菜单项"
        return 1
    fi

    gd=$(grep -oP '^GRUB_DEFAULT=\K.*' /etc/default/grub 2>/dev/null | head -1 || true)
    if [ "$gd" = "\"$path\"" ]; then
        ok "GRUB 默认引导项已指向 BBRv3（$path）"
        return 0
    fi

    local _esc="${path//&/\\&}"
    vpnplus_grub_backup || true
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null; then
        run sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$_esc\"|" /etc/default/grub
    else
        run bash -c "printf '%s\n' 'GRUB_DEFAULT=\"$_esc\"' >> /etc/default/grub"
    fi
    if ! command -v grub-script-check >/dev/null 2>&1 || grub-script-check /boot/grub/grub.cfg >/dev/null 2>&1; then
        info "grub.cfg 语法检查通过（或无 grub-script-check，直接更新）"
    else
        warn "现 grub.cfg 语法异常，仍尝试更新（已备份，失败可回滚）"
    fi
    if ! vpnplus_grub_update; then
        warn "GRUB 默认项可能未保存（已备份，见 \$BAK_DIR/grub-*）"
        return 1
    fi
    ok "GRUB 默认引导项已设为 BBRv3：$path"
    local setdef
    setdef=$(grep -oP '^[[:space:]]*set default=\K.*' /boot/grub/grub.cfg 2>/dev/null | tail -1 || true)
    [ -n "$setdef" ] && info "grub.cfg: set default=$setdef"
    return 0
}
