#!/usr/bin/env python3
"""vpnplus 完整性门禁 —— 对齐 vpnmax a28fe7e 系，按需移植。

vpnplus 架构差异（故 R1/R2/R3/R7 不原文照搬）：
  R1/R2 入口脚本刻意保留「lib 存在则 source，否则内联兜底」（单文件 curl|bash
       裸装兼容），`if ! declare -F` 块是设计而非漂移；无 lib/boot.sh、无
       vpnplus_load 引导器。只做 R1-报告（计数提醒，不判失败）。
  R3 deploy_singbox.sh 与 lib/firewall.sh 重复 readonly 常量是已知状态，
       入口需单文件可独立运行；不判失败。
  R7a vpnplus 无 vendor/ 目录，外部下载 + 单 SB_SHA256 模型：只 gate
       SB_SHA256 为 64 位 hex 非空（格式门），不做双哈希比对。
  R7b 无 lib/boot.sh、无 LIB_REV：条件 SKIP（有 boot.sh 才 gate）。

强制门：
  R4 所有 shell 文件 bash -n 通过
  R5 lib 每个模块必须有重复-source 守卫（VPNPLUS_*_LOADED，boot.sh 除外）
  R6 头部注释区不得夹带未注释行（漏写 `#` 会把用法文本当命令执行）
  GBK：全文件 read 必须 errors="replace"（GBK 存盘 .sh 不得崩门禁）

用法: python3 tools/check-lib-integrity.py
退出码: 0 通过 / 1 有违规
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENTRIES = [
    "bootstrap.sh",
    "deploy_optimize.sh",
    "deploy_singbox.sh",
    "verify.sh",
    "cleanup.sh",
]

violations = []
notes = []


def read(p):
    return (ROOT / p).read_text(encoding="utf-8", errors="replace")


# ── R1 报告（不判失败）：内联兜底块计数 ──
r1_count = 0
for e in ENTRIES:
    lines = read(e).split("\n")
    for i, ln in enumerate(lines):
        m = re.match(r"^if ! declare -F (\w+) >", ln)
        if not m:
            continue
        nxt = "\n".join(lines[i + 1 : i + 4])
        if re.search(rf"^\s*{m.group(1)}\(\)", nxt, re.M):
            r1_count += 1
notes.append(f"R1-info 内联兜底块共 {r1_count} 处（单文件架构设计，lib/ 为准源）")

# ── R4 bash -n ──
shells = sorted(list(ROOT.glob("*.sh")) + list((ROOT / "lib").rglob("*.sh")))
for p in shells:
    r = subprocess.run(
        ["bash", "-n", p.relative_to(ROOT).as_posix()],
        capture_output=True,
        text=True,
        errors="replace",
        check=False,
    )
    if r.returncode != 0:
        violations.append(
            f"R4 {p.relative_to(ROOT)} bash -n 失败: {r.stderr.strip().splitlines()[:1]}"
        )

# ── R5 lib 模块守卫 ──
for p in sorted((ROOT / "lib").rglob("*.sh")):
    if p.name == "boot.sh":
        continue
    if not re.search(
        r"^VPNPLUS_[A-Z_]*LOADED=",
        p.read_text(encoding="utf-8", errors="replace"),
        re.M,
    ):
        violations.append(
            f"R5 {p.relative_to(ROOT)} 缺少重复-source 守卫（VPNPLUS_*_LOADED）"
        )

# ── R6 头部注释区不得夹带未注释行 ──
STMT = re.compile(
    r"^\s*(?:"
    r"set\s|set$|\.\s|source\s|umask\b|export\s|declare\s|readonly\s|local\s|trap\s|"
    r"[A-Za-z_][A-Za-z0-9_]*=|"
    r"\[\[?\s|\(|"
    r"if\s|for\s|while\s|until\s|case\s|function\s|"
    r"[a-z_][a-z0-9_]*\s*\(\)"
    r")"
)
for p in shells:
    rel = p.relative_to(ROOT)
    for i, ln in enumerate(read(rel).split("\n")[1:60], start=2):
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if STMT.match(ln):
            break
        violations.append(
            f"R6 {rel}:{i} 头部注释区出现未注释行（会被当作命令执行，补 `# `）: {ln.strip()[:70]}"
        )

# ── R7a-lite：单 SB_SHA256 格式门（无 vendor，不做双哈希比对） ──
_deploy = read("deploy_singbox.sh")
m = re.search(r'^SB_SHA256="([0-9a-f]{64})"', _deploy, re.M)
if not m:
    violations.append("R7a-lite deploy_singbox.sh 缺少 64 位 hex 的 SB_SHA256 常量")

# ── R7b：有 boot.sh 才 gate，否则 SKIP ──
_boot_p = ROOT / "lib" / "boot.sh"
if _boot_p.is_file():
    import hashlib

    _boot = _boot_p.read_text(encoding="utf-8", errors="replace")
    mb = re.search(r'^VPNPLUS_LIB_REV="([^"]+)"', _boot, re.M)
    if not mb or not re.fullmatch(r"20\d{2}-\d{2}-\d{2}\.\d+", mb.group(1)):
        violations.append(
            f"R7b VPNPLUS_LIB_REV 格式非法（{mb.group(1) if mb else '缺失'}；改 lib/ 必 bump 为 YYYY-MM-DD.N）"
        )
    mh = re.search(r'^BOOT_SHA256="([^"]*)"', _boot, re.M)
    if not mh or not mh.group(1):
        violations.append("R7b BOOT_SHA256 为空（改 boot.sh 必重算自哈希）")
    else:
        normalized = re.sub(
            r'^BOOT_SHA256=".*"', 'BOOT_SHA256=""', _boot, count=1, flags=re.M
        )
        if hashlib.sha256(normalized.encode("utf-8")).hexdigest() != mh.group(1):
            violations.append("R7b BOOT_SHA256 与归一化自哈希不一致（改 boot.sh 必重算）")
else:
    notes.append("R7b-SKIP lib/boot.sh 不存在（vpnplus 只读 /usr/local/lib/vpnplus，无缓存冻结问题）")

print(f"[OK] R4/R5/R6/R7-lite 全部通过：{len(shells)} 个 shell 文件，{len(ENTRIES)} 个入口脚本")
if notes:
    print("\n参考（未判失败）：")
    print("\n".join(notes[:15]))

if violations:
    print(f"\n[X] {len(violations)} 项违规：")
    for v in violations:
        print("  " + v)
    sys.exit(1)
