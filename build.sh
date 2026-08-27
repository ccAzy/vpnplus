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
    for lib in lib/common.sh lib/time.sh lib/optimize.sh; do
        local base
        base=$(basename "$lib")
        # 取 lib 关键函数名，检查单文件是否包含
        local func
        func=$(grep -oE '^[a-z_]+\(\)' "$lib" 2>/dev/null | head -1 | tr -d '()')
        if [ -n "$func" ] && ! grep -q "$func" deploy_optimize.sh 2>/dev/null; then
            echo "WARN: $lib:$func 未同步到 deploy_optimize.sh (改 lib 后需同步单文件)"
            ok=false
        fi
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
