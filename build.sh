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

# deploy_optimize 单文件 = 头 + lib/common + lib/time + lib/optimize + 主体编排
# 为简化，现阶段直接拷贝已自包含的原文件（已含 fallback），保证 curl 可用
# 下一阶段可改为真正内联组装
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
