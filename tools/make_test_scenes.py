#!/usr/bin/env python3
"""生成透视畸变的模拟手机拍摄场景，用于离线压测 ArUco 检测器。

场景 = "Mac 屏幕"（1728x1117，照片纹理背景 + 四角白卡定位码）
经随机单应 warp 进 1280x720 的"相机帧"，加模糊与噪声。
输出: scenes/scene_NN.png + scenes/scene_NN.json（标记中心真值 + 逻辑坐标 + 瞄准点真值）
"""
import json
import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "scenes"
OUT.mkdir(exist_ok=True)

SCREEN_W, SCREEN_H = 1728, 1117          # 模拟 Mac 屏幕（pt=px）
MARKER = 48                              # 标记边长（24pt @2x 的观感）
INSET = 24                               # 与 Calibrator 默认 inset 一致
FRAME_W, FRAME_H = 1280, 720             # 相机帧


def solve_homography(src, dst):
    """4 点 DLT：src -> dst，返回 3x3 矩阵"""
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
    A = np.asarray(A)
    # 高斯消元
    n = 8
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(A[r, col]))
        A[[col, piv]] = A[[piv, col]]
        A[col] /= A[col, col]
        for r in range(n):
            if r != col:
                A[r] -= A[r, col] * A[col]
    h = A[:, 8]
    return np.array([[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1.0]])


def pil_perspective_coeffs(H_inv):
    """PIL PERSPECTIVE 系数：输出 -> 输入 映射"""
    H = H_inv / H_inv[2, 2]
    return [H[0, 0], H[0, 1], H[0, 2], H[1, 0], H[1, 1], H[1, 2], H[2, 0], H[2, 1]]


def apply(H, x, y):
    v = H @ np.array([x, y, 1.0])
    return v[0] / v[2], v[1] / v[2]


def make_screen(rng, bg_photo, marker_px):
    """合成屏幕画面：照片背景 + 四角白卡 + 标记"""
    global MARKER
    MARKER = marker_px
    screen = bg_photo.resize((SCREEN_W, SCREEN_H), Image.LANCZOS).convert("L")
    # 屏幕比环境亮，拉升亮度
    screen = screen.point(lambda v: min(255, int(v * 0.55 + 110)))
    centers = [
        (INSET + MARKER / 2, INSET + MARKER / 2),                          # 0 左上
        (SCREEN_W - INSET - MARKER / 2, INSET + MARKER / 2),               # 1 右上
        (SCREEN_W - INSET - MARKER / 2, SCREEN_H - INSET - MARKER / 2),    # 2 右下
        (INSET + MARKER / 2, SCREEN_H - INSET - MARKER / 2),               # 3 左下
    ]
    pad = 16  # 白卡边距（8pt @2x）
    for i, (cx, cy) in enumerate(centers):
        marker = Image.open(ROOT / "markers" / f"marker_{i}.png").convert("L")
        marker = marker.resize((MARKER, MARKER), Image.NEAREST)
        # 白卡
        card = Image.new("L", (MARKER + pad * 2, MARKER + pad * 2), 255)
        card.paste(marker, (pad, pad))
        screen.paste(card, (int(cx - MARKER / 2 - pad), int(cy - MARKER / 2 - pad)))
    return screen, centers


def gen_scene(idx, rng, bg_photo, marker_px=MARKER):
    screen, centers = make_screen(rng, bg_photo, marker_px)

    # 随机视角：屏幕四角在相机帧中的落点（屏幕占画面宽度 85-100%，带梯形畸变与少量旋转）
    margin_x = rng.uniform(0.0, 0.10) * FRAME_W
    margin_top = rng.uniform(0.02, 0.15) * FRAME_H
    skew = rng.uniform(-0.08, 0.08)
    tilt = rng.uniform(-0.1, 0.1)
    dst = [
        (margin_x + rng.uniform(-20, 20), margin_top + rng.uniform(-15, 15)),
        (FRAME_W - margin_x * (1 + skew) + rng.uniform(-20, 20), margin_top * (1 + tilt) + rng.uniform(-15, 15)),
        (FRAME_W - margin_x * (1 - skew) + rng.uniform(-20, 20), FRAME_H - margin_top * (1 - tilt) + rng.uniform(-15, 15)),
        (margin_x * (1 + tilt) + rng.uniform(-20, 20), FRAME_H - margin_top * (1 + tilt) + rng.uniform(-15, 15)),
    ]
    src = [(0, 0), (SCREEN_W, 0), (SCREEN_W, SCREEN_H), (0, SCREEN_H)]
    H_screen_to_frame = solve_homography(np.array(src), np.array(dst))

    coeffs = pil_perspective_coeffs(np.linalg.inv(H_screen_to_frame))
    frame = screen.transform((FRAME_W, FRAME_H), Image.PERSPECTIVE, coeffs,
                             resample=Image.BICUBIC)
    # 屏幕外的区域填环境暗色（模拟桌面）
    mask = Image.new("L", (1, 1), 255).resize((SCREEN_W, SCREEN_H))
    mask = mask.transform((FRAME_W, FRAME_H), Image.PERSPECTIVE, coeffs, resample=Image.BILINEAR)
    ambient = bg_photo.resize((FRAME_W, FRAME_H), Image.LANCZOS).convert("L").point(lambda v: v // 3)
    frame = Image.composite(frame, ambient, mask)

    # 模糊 + 噪声（模拟手机镜头与压缩）
    frame = frame.filter(ImageFilter.GaussianBlur(radius=rng.uniform(0.4, 1.0)))
    arr = np.asarray(frame).astype(np.int16)
    noise = rng.integers(-8, 9, arr.shape)
    arr = np.clip(arr + noise, 0, 255).astype(np.uint8)
    frame = Image.fromarray(arr)

    img_path = OUT / f"scene_{idx:02d}.png"
    frame.save(img_path)

    # 真值：标记中心在相机帧中的位置；瞄准点真值 = 帧中心反映射回屏幕坐标
    H_frame_to_screen = np.linalg.inv(H_screen_to_frame)
    truth_centers = {str(i): list(apply(H_screen_to_frame, cx, cy)) for i, (cx, cy) in enumerate(centers)}
    aim_truth = apply(H_frame_to_screen, FRAME_W / 2, FRAME_H / 2)
    gt = {
        "markers": truth_centers,
        "logical": {str(i): [cx, cy] for i, (cx, cy) in enumerate(centers)},
        "aimTruth": list(aim_truth),
    }
    (OUT / f"scene_{idx:02d}.json").write_text(json.dumps(gt, indent=1))
    print(f"scene_{idx:02d}: aim_truth=({aim_truth[0]:.1f}, {aim_truth[1]:.1f})")


if __name__ == "__main__":
    rng = np.random.default_rng(42)
    random.seed(42)
    # 用工作区实拍照片当纹理（桌面杂物 + 屏幕感）
    bg = Image.open(ROOT / "aimphone_bar_fixed.png")
    # 标记尺寸梯度：48px(轻松) / 36px / 24px（24pt@1728 在屏幕铺满 720p 帧时的真实观感）
    sizes = [48, 48, 36, 36, 24, 24, 24, 24]
    for i in range(8):
        gen_scene(i, np.random.default_rng(100 + i), bg, marker_px=sizes[i])
    print("done ->", OUT)
