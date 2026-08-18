#!/usr/bin/env python3
"""IMU 采样基线分析（WP-I1，docs/imu-fusion-plan.md §1）：回答四个决策问题。

用法:
    python tools/plot_imu_baseline.py scenes/capture_xxx [scenes/capture_yyy ...]
    python tools/plot_imu_baseline.py            # 自动取 scenes/ 下所有含 motion 字段的 capture_*

每个会话输出一张 4 面板 PNG（<目录名>_imu.png），stdout 打印四问结论表与决策门判定。

四问（与方案 §1 逐条对应）：
  Q1 时间轴：每帧 PTS 与最近 motion 样本的对齐残差分布（两时钟同为 mach boot 的实测验证）
  Q2 轴向映射：相邻有瞄准点帧之间，屏幕位移 (dx,dy) 对三轴角增量 Δθx/Δθy/Δθz 的相关
  Q3 比例系数：px/rad = |Δaim| / |Δθ_主平面| 的同会话散布（±%）与跨距离组中位数对比
  Q4 漂移率：最长静止窗内 rotationRate 积分漂移与姿态四元数端点漂移（°/s），
     折算 120ms 外推的像素误差
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
import matplotlib.pyplot as plt

# 中文字体（macOS）：失败则退化默认字体，仅影响图内文字
for f in ("PingFang SC", "Hiragino Sans GB", "Arial Unicode MS"):
    try:
        from matplotlib import font_manager
        font_manager.findfont(f, fallback_to_default=False)
        plt.rcParams["font.sans-serif"] = [f]
        break
    except Exception:
        continue
plt.rcParams["axes.unicode_minus"] = False

ROOT = Path(__file__).resolve().parent.parent
AXES = ("x", "y", "z")

# 静止判据：|ω| 低于此值视为静止（rad/s）。消费级 MEMS 静止噪声典型 σ≈0.005–0.02
STATIC_RATE = 0.05
# Q3 角增量显著性门槛：小于此值的帧对不参于 px/rad 统计（陀螺噪声主导，比值无意义）
MIN_DTHETA = 0.004


def load_session(d: Path):
    """读 meta.jsonl → (frames 表, 统一运动时间线)。无 motion 字段返回 None。"""
    meta = d / "meta.jsonl"
    if not meta.exists():
        return None
    frames = []
    samples = {}  # t -> (wx,wy,wz,qx,qy,qz,qw)，窗口重叠去重
    for line in meta.read_text().splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("kind") != "frame" or "motion" not in row:
            continue
        pts = row["pts"]
        frames.append(dict(seq=row["seq"], pts=pts,
                           x=row.get("x"), y=row.get("y")))
        for s in row["motion"]["samples"]:
            dt, wx, wy, wz, qx, qy, qz, qw = s
            t = pts + dt
            samples[t] = (t, wx, wy, wz, qx, qy, qz, qw)
    if not frames or len(samples) < 20:
        return None
    frames.sort(key=lambda r: r["pts"])
    ts = np.array(sorted(samples))
    mot = np.array([samples[t] for t in ts])  # 列: t,wx,wy,wz,qx,qy,qz,qw
    return frames, mot


def label_of(d: Path) -> str:
    """目录名 capture_<label>_<ISO时间戳> → label（无 label 的旧目录取整名）"""
    name = d.name
    body = name[len("capture_"):] if name.startswith("capture_") else name
    parts = body.rsplit("_", 1)
    if len(parts) == 2 and parts[1][:4].isdigit():
        return parts[0]
    return body


def q1_alignment(frames, mot):
    """每帧 PTS 找最近 motion 样本，残差 ms。"""
    res = []
    for f in frames:
        i = np.searchsorted(mot[:, 0], f["pts"])
        cand = [abs(mot[j, 0] - f["pts"]) for j in (i - 1, i) if 0 <= j < len(mot)]
        if cand:
            res.append(min(cand) * 1000)
    res = np.array(res)
    dt = np.diff(mot[:, 0]) * 1000
    return res, dt


def frame_pairs(frames, mot):
    """相邻都有瞄准点的帧对 → (dt, Δaim 向量, Δθ 三轴向量（梯形积分）)。"""
    out = []
    for a, b in zip(frames, frames[1:]):
        if a["x"] is None or b["x"] is None:
            continue
        t0, t1 = a["pts"], b["pts"]
        if t1 - t0 <= 0.01:
            continue
        sel = mot[(mot[:, 0] >= t0 - 1e-9) & (mot[:, 0] <= t1 + 1e-9)]
        if len(sel) < 2:
            continue
        dth = np.array([
            np.trapezoid(sel[:, 1], sel[:, 0]),
            np.trapezoid(sel[:, 2], sel[:, 0]),
            np.trapezoid(sel[:, 3], sel[:, 0]),
        ])
        daim = np.array([b["x"] - a["x"], b["y"] - a["y"]])
        out.append((t1 - t0, daim, dth))
    return out


def q2_axes(pairs):
    """dx/dy 对三轴角增量的 Pearson 相关；返回 {分量: {轴: (r, n)}} 与主轴结论。"""
    if len(pairs) < 8:
        return None
    daim = np.array([p[1] for p in pairs])
    dth = np.array([p[2] for p in pairs])
    # 只在运动量足够大的帧对上算相关，静止段全噪底会稀释相关系数
    mag = np.linalg.norm(dth, axis=1)
    big = mag > np.percentile(mag, 40)
    if big.sum() < 6:
        big = np.ones(len(pairs), bool)
    r = {}
    for ci, name in ((0, "dx"), (1, "dy")):
        r[name] = {}
        for ai, ax in enumerate(AXES):
            v, w = daim[big, ci], dth[big, ai]
            if v.std() < 1e-9 or w.std() < 1e-12:
                r[name][ax] = 0.0
            else:
                r[name][ax] = float(np.corrcoef(v, w)[0, 1])
    return r, int(big.sum())


def q3_scale(pairs, dom_axes):
    """px/rad：主平面角增量模长上的位移/转角比。dom_axes = (dx主轴, dy主轴)。"""
    vals = []
    for dt, daim, dth in pairs:
        plane = math.hypot(dth[AXES.index(dom_axes[0])],
                           dth[AXES.index(dom_axes[1])])
        if plane < MIN_DTHETA:
            continue
        vals.append(math.hypot(*daim) / plane)
    return np.array(vals)


def q4_drift(mot):
    """最长静止窗：rotationRate 积分漂移 + 四元数端点姿态差。返回 dict 或 None。"""
    rate = np.linalg.norm(mot[:, 1:4], axis=1)
    still = rate < STATIC_RATE
    best = (0, 0)  # (start, end) 最长连续静止段
    i = 0
    while i < len(still):
        if not still[i]:
            i += 1
            continue
        j = i
        while j + 1 < len(still) and still[j + 1]:
            j += 1
        if mot[j, 0] - mot[i, 0] > mot[best[1], 0] - mot[best[0], 0]:
            best = (i, j)
        i = j + 1
    i, j = best
    dur = mot[j, 0] - mot[i, 0]
    if dur < 2.0:
        return None
    seg = mot[i:j + 1]
    # 原始角速度直接积分（WP-I2 外推的误差源：零偏残差 + 噪声游走）
    drift_vec = np.array([np.trapezoid(seg[:, k], seg[:, 0]) for k in (1, 2, 3)])
    integ_deg_s = math.degrees(np.linalg.norm(drift_vec)) / dur
    bias = seg[:, 1:4].mean(axis=0)          # 零偏残差（rad/s），决定线性漂移主项
    bias_deg_s = math.degrees(np.linalg.norm(bias))
    # 姿态四元数端点差（CoreMotion 融合输出自身的漂移，xArbitraryZVertical 无磁北校正）
    q0, q1 = seg[0, 4:8], seg[-1, 4:8]
    dq = abs(float(np.dot(q0, q1)))          # |q0·q1| = cos(Δθ/2)
    quat_deg_s = math.degrees(2 * math.acos(min(1.0, dq))) / dur
    return dict(dur=dur, integ_deg_s=integ_deg_s, bias_deg_s=bias_deg_s,
                quat_deg_s=quat_deg_s)


def pct(a, p):
    return float(np.percentile(a, p)) if len(a) else float("nan")


def analyze(d: Path):
    loaded = load_session(d)
    if not loaded:
        print(f"[跳过] {d.name}: 无 motion 字段（旧采集）")
        return None
    frames, mot = loaded
    label = label_of(d)
    res, dt = q1_alignment(frames, mot)
    pairs = frame_pairs(frames, mot)
    q2 = q2_axes(pairs)
    drift = q4_drift(mot)

    print(f"\n=== {d.name} ===")
    print(f"帧数={len(frames)}  motion样本={len(mot)}  "
          f"采样周期中位={np.median(dt):.1f}ms")
    print(f"Q1 对齐残差(ms): p50={pct(res,50):.2f} p95={pct(res,95):.2f} "
          f"max={res.max():.2f}（100Hz 理论上限 5ms）")

    dom = None
    scale = np.array([])
    if q2:
        r, n = q2
        dom = (max(r["dx"], key=lambda a: abs(r["dx"][a])),
               max(r["dy"], key=lambda a: abs(r["dy"][a])))
        print(f"Q2 轴向相关（n={n} 运动帧对）: "
              f"dx↔θx={r['dx']['x']:+.2f} θy={r['dx']['y']:+.2f} θz={r['dx']['z']:+.2f} → 主θ{dom[0]} | "
              f"dy↔θx={r['dy']['x']:+.2f} θy={r['dy']['y']:+.2f} θz={r['dy']['z']:+.2f} → 主θ{dom[1]}")
        scale = q3_scale(pairs, dom)
        if len(scale) >= 5:
            med = pct(scale, 50)
            spread = (pct(scale, 84) - pct(scale, 16)) / 2 / med * 100
            print(f"Q3 px/rad: 中位={med:.0f} ±散布={spread:.1f}% "
                  f"(p16={pct(scale,16):.0f} p84={pct(scale,84):.0f}, n={len(scale)})")
        else:
            print(f"Q3 px/rad: 有效帧对不足（n={len(scale)}）")
    else:
        print("Q2/Q3: 有瞄准点的帧对不足，无法相关分析")

    if drift:
        med_scale = pct(scale, 50) if len(scale) >= 5 else float("nan")
        # 120ms 外推误差：零偏主项 × 0.12s（°→px 用本组中位 px/rad）
        err120 = math.radians(drift["bias_deg_s"]) * 0.12 * med_scale
        print(f"Q4 漂移: 静止窗={drift['dur']:.1f}s "
              f"零偏={drift['bias_deg_s']:.3f}°/s "
              f"积分漂移={drift['integ_deg_s']:.3f}°/s "
              f"姿态端点={drift['quat_deg_s']:.3f}°/s "
              f"→ 120ms 外推误差≈{err120:.2f}px")
    else:
        print("Q4: 无 ≥2s 静止窗")

    plot_session(d, label, frames, mot, res, pairs, dom, scale, drift)
    return dict(dir=d, label=label, dom=dom, scale=scale, drift=drift,
                med_scale=pct(scale, 50) if len(scale) >= 5 else float("nan"))


def plot_session(d, label, frames, mot, res, pairs, dom, scale, drift):
    t = mot[:, 0] - mot[0, 0]
    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    fig.suptitle(f"IMU 基线 — {d.name}", fontsize=12)

    ax = axes[0, 0]
    ax.hist(res, bins=20, color="tab:blue")
    ax.set_title(f"Q1 对齐残差（p95={pct(res,95):.2f}ms）")
    ax.set_xlabel("|t_motion - PTS| (ms)")

    ax = axes[0, 1]
    ax.plot(t, mot[:, 1], lw=0.7, label="ωx")
    ax.plot(t, mot[:, 2], lw=0.7, label="ωy")
    ax.plot(t, mot[:, 3], lw=0.7, label="ωz")
    ax.set_title("角速度时间线 (rad/s)")
    ax.set_xlabel("s")
    ax.legend(fontsize=8)

    ax = axes[1, 0]
    if pairs and dom:
        daim = np.array([math.hypot(*p[1]) for p in pairs])
        plane = np.array([math.hypot(p[2][AXES.index(dom[0])],
                                     p[2][AXES.index(dom[1])]) for p in pairs])
        m = plane > MIN_DTHETA
        ax.scatter(np.degrees(plane[m]), daim[m], s=12, alpha=0.6)
        ax.set_xlabel(f"主平面角增量 θ{dom[0]}/θ{dom[1]} (°)")
        ax.set_ylabel("|Δaim| (px)")
        ax.set_title("Q2/Q3 位移-转角散点")
    else:
        ax.set_title("Q2/Q3 位移-转角散点（数据不足）")

    ax = axes[1, 1]
    if len(scale):
        ax.plot(scale, ".", ms=5, alpha=0.6)
        med = pct(scale, 50)
        ax.axhline(med, color="tab:red", lw=1, label=f"中位 {med:.0f} px/rad")
        ax.legend(fontsize=8)
    ax.set_title("Q3 px/rad 逐帧对（显著运动）")
    ax.set_xlabel("帧对序号")
    if drift:
        ax.set_xlabel(f"帧对序号 | Q4 静止窗 {drift['dur']:.1f}s "
                      f"零偏 {drift['bias_deg_s']:.3f}°/s")

    out = d.parent / f"{d.name}_imu.png"
    fig.tight_layout()
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"图已保存: {out}")


def gate_summary(results):
    """跨会话决策门汇总（方案 §1 验收门）。"""
    print("\n========== 决策门汇总 ==========")
    ok = [r for r in results if r]
    if not ok:
        print("无有效会话")
        return
    # Q3：按距离分组（label 中含 dNN 距离标记时分组，否则全体一组）
    groups = {}
    for r in ok:
        dist = next((tok for tok in r["label"].split("_") if tok.startswith("d")
                     and tok[1:].isdigit()), "all")
        groups.setdefault(dist, []).append(r)
    for dist, rs in sorted(groups.items()):
        all_scale = np.concatenate([r["scale"] for r in rs if len(r["scale"])])
        if len(all_scale) < 5:
            print(f"Q3 距离组 {dist}: 样本不足")
            continue
        med = pct(all_scale, 50)
        spread = (pct(all_scale, 84) - pct(all_scale, 16)) / 2 / med * 100
        verdict = "达标(<±20%)" if spread < 20 else "超标(≥±20%)"
        print(f"Q3 距离组 {dist}: 中位={med:.0f}px/rad 同距离散布=±{spread:.1f}% → {verdict}")
    if len(groups) > 1 and "all" not in groups:
        meds = {g: pct(np.concatenate([r["scale"] for r in rs if len(r["scale"])]), 50)
                for g, rs in groups.items()}
        print(f"Q3 跨距离中位数: {meds}")
    # Q4：120ms 外推误差取各会话中位
    errs = []
    for r in ok:
        if r["drift"] and not math.isnan(r["med_scale"]):
            errs.append(math.radians(r["drift"]["bias_deg_s"]) * 0.12 * r["med_scale"])
    if errs:
        med_err = float(np.median(errs))
        verdict = "支持 ≥120ms 外推" if med_err < 1.0 else "外推误差偏大，需更短封顶"
        print(f"Q4 120ms 外推误差: 中位={med_err:.2f}px max={max(errs):.2f}px → {verdict}")


def main():
    args = [Path(a) for a in sys.argv[1:]]
    if not args:
        args = [d for d in sorted((ROOT / "scenes").glob("capture_*"))
                if (d / "meta.jsonl").exists()
                and '"motion"' in (d / "meta.jsonl").read_text()[:200000]]
        if not args:
            sys.exit("scenes/ 下没有含 motion 字段的采集会话，先真机录制（WP-I1）")
    results = [analyze(d) for d in args]
    gate_summary(results)


if __name__ == "__main__":
    main()
