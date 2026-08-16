#!/usr/bin/env python3
"""Phase 1.2/1.3 验收基准场景生成（补充 make_test_scenes.py）：

- scenes/bench20_NN.png：20pt 标记（40px @1728 屏）随机视角 8 组，测小标记命中率
- scenes/bench20far_NN.png：20pt 远距离组（屏幕占画面 30–50% 宽），低命中率复现区间
- scenes/static48_NN.png：24pt 标记（48px）固定视角 24 帧（仅噪声不同），测静止 σ

几何/真值生成复用 make_test_scenes 的函数；背景纹理改用 icons/ 下的图
（make_test_scenes 依赖的 aimphone_bar_fixed.png 已不在工作区）。
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import make_test_scenes as M

OUT = ROOT / "scenes"


def random_dst(rng, far=False, mid=False):
    """与 make_test_scenes.gen_scene 相同的随机视角分布；
    mid=True 屏幕占画面 ~56–70% 宽（正常工作距离上限，帧上标记 ~15–20px）；
    far=True 时屏幕只占画面宽约 30–50%（分辨率极限区，对照用）"""
    if far:
        margin_x = rng.uniform(0.25, 0.35) * M.FRAME_W
        margin_top = rng.uniform(0.15, 0.3) * M.FRAME_H
    elif mid:
        margin_x = rng.uniform(0.15, 0.22) * M.FRAME_W
        margin_top = rng.uniform(0.08, 0.18) * M.FRAME_H
    else:
        margin_x = rng.uniform(0.0, 0.10) * M.FRAME_W
        margin_top = rng.uniform(0.02, 0.15) * M.FRAME_H
    skew = rng.uniform(-0.08, 0.08)
    tilt = rng.uniform(-0.1, 0.1)
    return [
        (margin_x + rng.uniform(-20, 20), margin_top + rng.uniform(-15, 15)),
        (M.FRAME_W - margin_x * (1 + skew) + rng.uniform(-20, 20),
         margin_top * (1 + tilt) + rng.uniform(-15, 15)),
        (M.FRAME_W - margin_x * (1 - skew) + rng.uniform(-20, 20),
         M.FRAME_H - margin_top * (1 - tilt) + rng.uniform(-15, 15)),
        (margin_x * (1 + tilt) + rng.uniform(-20, 20),
         M.FRAME_H - margin_top * (1 + tilt) + rng.uniform(-15, 15)),
    ]


def gen(name, rng, bg, marker_px, dst, blur):
    screen, centers = M.make_screen(rng, bg, marker_px)
    src = [(0, 0), (M.SCREEN_W, 0), (M.SCREEN_W, M.SCREEN_H), (0, M.SCREEN_H)]
    H_s2f = M.solve_homography(np.array(src), np.array(dst))
    coeffs = M.pil_perspective_coeffs(np.linalg.inv(H_s2f))
    frame = screen.transform((M.FRAME_W, M.FRAME_H), Image.PERSPECTIVE, coeffs,
                             resample=Image.BICUBIC)
    mask = Image.new("L", (1, 1), 255).resize((M.SCREEN_W, M.SCREEN_H))
    mask = mask.transform((M.FRAME_W, M.FRAME_H), Image.PERSPECTIVE, coeffs,
                          resample=Image.BILINEAR)
    ambient = bg.resize((M.FRAME_W, M.FRAME_H), Image.LANCZOS).convert("L") \
        .point(lambda v: v // 3)
    frame = Image.composite(frame, ambient, mask)
    frame = frame.filter(ImageFilter.GaussianBlur(radius=blur))
    arr = np.asarray(frame).astype(np.int16)
    arr = np.clip(arr + rng.integers(-8, 9, arr.shape), 0, 255).astype(np.uint8)
    Image.fromarray(arr).save(OUT / f"{name}.png")

    H_f2s = np.linalg.inv(H_s2f)
    truth = {str(i): list(M.apply(H_s2f, cx, cy)) for i, (cx, cy) in enumerate(centers)}
    gt = {
        "markers": truth,
        "logical": {str(i): [cx, cy] for i, (cx, cy) in enumerate(centers)},
        "aimTruth": list(M.apply(H_f2s, M.FRAME_W / 2, M.FRAME_H / 2)),
    }
    (OUT / f"{name}.json").write_text(json.dumps(gt, indent=1))


if __name__ == "__main__":
    bg = Image.open(ROOT / "icons" / "screenaim_icon_clean.png")
    # 20pt 命中率组：8 组随机视角（与 make_test_scenes 同分布）
    for i in range(8):
        rng = np.random.default_rng(300 + i)
        gen(f"bench20_{i:02d}", rng, bg, 40,
            dst=random_dst(rng), blur=rng.uniform(0.4, 1.0))
    # 20pt 中距离组：正常工作距离上限（帧上标记 ~15–20px），角点偏差主导解码失败
    for i in range(8):
        rng = np.random.default_rng(500 + i)
        gen(f"bench20mid_{i:02d}", rng, bg, 40,
            dst=random_dst(rng, mid=True), blur=rng.uniform(0.5, 1.0))
    # 20pt 中距离 + 重失焦模糊组（1.5–2.0px，模拟真实手机虚焦/运动糊）：
    # 角点偏 1px 在糊边上会被进一步放大，是实机 20pt 低命中率的主要复现手段
    for i in range(8):
        rng = np.random.default_rng(600 + i)
        gen(f"bench20blur_{i:02d}", rng, bg, 40,
            dst=random_dst(rng, mid=True), blur=rng.uniform(1.0, 1.5))
    # 20pt 远距离组：屏幕占画面 30–50% 宽（帧上标记 ~8–15px），分辨率极限对照区
    for i in range(8):
        rng = np.random.default_rng(400 + i)
        gen(f"bench20far_{i:02d}", rng, bg, 40,
            dst=random_dst(rng, far=True), blur=rng.uniform(0.6, 1.2))
    # 静止 σ 组：固定视角 + 固定模糊，24 帧仅噪声种子不同（模拟手机静止连拍）
    geo_rng = np.random.default_rng(7)
    fixed_dst = random_dst(geo_rng)
    for i in range(24):
        gen(f"static48_{i:02d}", np.random.default_rng(900 + i), bg, 48,
            dst=fixed_dst, blur=0.7)
    print("done ->", OUT)
