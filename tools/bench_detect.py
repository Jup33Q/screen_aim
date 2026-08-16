#!/usr/bin/env python3
"""Phase 1.2/1.3 验收跑分：对一组基准场景跑纯 Swift 检测器并汇总指标。

用法:
    python tools/bench_detect.py 'scenes/bench20_*.png'     # 命中率（对 4 标记真值）
    python tools/bench_detect.py 'scenes/static48_*.png'    # 静止 σ（瞄准点 + 标记中心）

调用 .build/debug/ScreenAim --swift-detect（需先 swift build），解析其 stdout。
"""
import glob
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / ".build" / "debug" / "ScreenAim"

pattern = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "scenes" / "bench20_*.png")
scenes = sorted(glob.glob(pattern, root_dir=ROOT if not Path(pattern).is_absolute() else None)
                if not Path(pattern).is_absolute() else glob.glob(pattern))
if not scenes:
    sys.exit(f"没有匹配的场景: {pattern}")

RE_SWIFT_COUNT = re.compile(r"== Swift 检出 (\d+) 个（([\d.]+) ms）==")
RE_SWIFT_MARKER = re.compile(r"^  id=(\d+) center=\(([\d.]+), ([\d.]+)\)$", re.M)
RE_AIM = re.compile(r"Swift 对真值: 中心最大误差 [\d.]+px, 瞄准点 \(([\d.]+), ([\d.]+)\) "
                    r"vs 真值 \(([\d.]+), ([\d.]+)\) 差 ([\d.]+)")

hit_markers = 0          # 检出的真值标记数（id 0-3 范围内）
total_scenes = 0
full_scenes = 0          # 4 角全检出的场景数
detect_ms = []
aim_errs = []            # 瞄准点对真值误差（pt）
aims = []                # 瞄准点坐标（静止 σ 用）
center_errs = []         # 单标记中心对真值误差（px）

for png in scenes:
    js = str(Path(png).with_suffix(".json"))
    out = subprocess.run([str(BIN), "--swift-detect", png, js],
                         capture_output=True, text=True, cwd=ROOT).stdout
    m = RE_SWIFT_COUNT.search(out)
    if not m:
        print(f"{Path(png).name}: 解析失败"); continue
    total_scenes += 1
    n, ms = int(m.group(1)), float(m.group(2))
    detect_ms.append(ms)
    # 只统计真值里的 4 个角标记（id 0-3）
    ids = [int(x[0]) for x in RE_SWIFT_MARKER.findall(out.split("== Swift")[1])]
    hit_markers += len([i for i in ids if i <= 3])
    if all(i in ids for i in range(4)):
        full_scenes += 1
    a = RE_AIM.search(out)
    if a:
        aims.append((float(a.group(1)), float(a.group(2))))
        aim_errs.append(float(a.group(5)))
    print(f"{Path(png).name}: 检出 {n}（角 {len([i for i in ids if i <= 3])}/4）"
          f" det={ms:.1f}ms" + (f" aim_err={a.group(5)}pt" if a else " aim=无"))

print("---- 汇总 ----")
print(f"场景数 {total_scenes}，角标记命中率 {hit_markers}/{total_scenes * 4}"
      f" = {hit_markers / (total_scenes * 4) * 100:.1f}%，"
      f"4 角集齐率 {full_scenes}/{total_scenes}")
print(f"检测耗时 p50={np.percentile(detect_ms, 50):.1f}ms")
if aim_errs:
    print(f"瞄准点误差（对真值）p50={np.percentile(aim_errs, 50):.2f}pt "
          f"max={max(aim_errs):.2f}pt")
if len(aims) >= 5:
    arr = np.array(aims)
    print(f"静止 σ（瞄准点，n={len(aims)}）：σx={arr[:, 0].std():.4f}pt "
          f"σy={arr[:, 1].std():.4f}pt σr={np.hypot(arr[:, 0].std(), arr[:, 1].std()):.4f}pt")
