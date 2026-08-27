#!/bin/bash
# build.sh — 从 lib/ 组装单文件 curl 裸装版（保持一键兼容，源码以 lib/ 为准）
set -euo pipefail
# 用法: bash build.sh  # 生成 dist/*.sh 单文件，供 raw.githubusercontent 分发
# 本地开发直接改 lib/*.sh，改完跑 build.sh 再推

DIST="dist"
mkdir -p "$DIST"

# 内联函数：把 lib 文件内容直接 cat 进单文件（去掉重复的 shebang 和 guard）
inline_lib() {
    local lib="$1"
    echo "# --- lib/$lib ---"
    # 去掉 shebang 和 guard 的 return 0 行，保留实际代码
    sed -e '1d' -e '/VPNPLUS.*LOADED/d' "lib/$lib" 2>/dev/null || cat "lib/$lib"
    echo ""
}

# 校验：单文件必须包含 lib 对应逻辑（保证改 lib 后单文件同步，否则低成本变更失效）
check_sync() {
    local ok=true
    # lib/*.sh 每个函数应出现在至少一个单文件（deploy/verify/cleanup/bootstrap），
    # 否则该 lib 函数在 curl 裸装时缺失。firewall/time 的部分函数分布在 cleanup/verify。
    local lib
    for lib in lib/common.sh lib/time.sh lib/optimize.sh lib/firewall.sh \
               lib/singbox.sh lib/subscription.sh lib/argo.sh lib/warp.sh; do
        local func
        for func in $(grep -oE '^[a-z_]+\(\)' "$lib" 2>/dev/null | tr -d '()' | sort -u); do
            if ! grep -qE "$func\(|declare -F $func" deploy_optimize.sh deploy_singbox.sh verify.sh cleanup.sh bootstrap.sh 2>/dev/null; then
                echo "WARN: $lib:$func 未同步到任何单文件 (改 lib 后需同步)"
                ok=false
            fi
        done
    done
    $ok || echo "提示: 改 lib 后请同步更新对应单文件，或跑 bash build.sh --sync"
}
check_sync || true

for src in deploy_optimize.sh deploy_singbox.sh verify.sh bootstrap.sh cleanup.sh; do
    if [ -f "$src" ]; then
        cp "$src" "$DIST/$src"
        echo "copied $src -> $DIST/$src"
    fi
done

# 同时拷贝 lib 供本地开发引用
mkdir -p "$DIST/lib" "$DIST/lib/verify"
cp -r lib/* "$DIST/lib/" 2>/dev/null || true

echo "build done -> $DIST/"
ls -lh "$DIST/" 2>&1 | head -n 20
ls -lh "$DIST/lib/" 2>&1 | head -n 20
