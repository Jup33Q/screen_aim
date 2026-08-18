#!/usr/bin/env python3
"""白点二维坐标连续性与抖动分析报告（scenes/localaim_*.csv，ScreenAim Mac 端记录）。

用法:
    python skills/aim-jitter-analysis/scripts/jitter_report.py [csv路径] [输出png路径]

- 不带参数时自动取 scenes/ 下最新的 localaim_*.csv
- 控制台输出指标表（连续性 / 静止抖动 / 跳变事件 / 分 quality 抖动），
  同时保存四面板图：dt 分布、帧间位移时间线、轨迹+跳变标记、最长静止段 PSD

数据坑（全部在此处理，勿在调用方重复处理）：
- timestamp 是 Mac 侧到达时刻（不是手机采集 PTS），dt 分布混入网络/调度抖动；
  同一 timestamp 连出多条 = 网络攒批到达（实测约占 20%），dt≈0 不除零
- x,y 为空 = 无瞄准点帧（检出 <4 或映射失败）；断流段不参与位移统计
- 旧文件无 quality 列（WP1 新增），脚本自动降级
- 跳变帧（单应翻转/标记掉检导致，实测可上万 pt）只标记不剔除，
  剔除会掩盖真实问题；但静止段判定用滚动中位数，对离群免疫
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))  # daimon_runtime

from daimon_runtime import setup_plot
import numpy as np
import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt

setup_plot()

ROOT = Path(__file__).resolve().parents[3]   # workspace 根（skills/<name>/scripts/ 上三级）
GAP_S = 0.5              # dt 超过此值记一次断流（协议 §7 名义上报 15Hz，500ms ≈ 7 帧）
BURST_S = 0.005          # dt 低于此值记为网络攒批同到达
STILL_DISP_PT = 2.0      # 静止段判定：滚动窗口帧间位移中位数低于此值（pt）
STILL_WIN = 15           # 静止段滚动窗口（帧，≈1s @15Hz）
JUMP_MIN_PT = 20.0       # 跳变事件绝对下限（pt），低于此值不可能是单应翻转
JUMP_MAD_K = 8.0         # 跳变事件相对门限：> K × 滚动 MAD


def pick_csv() -> Path:
    files = sorted((ROOT / "scenes").glob("localaim_*.csv"),
                   key=lambda p: p.stat().st_mtime)
    if not files:
        sys.exit("scenes/ 下没有 localaim_*.csv，先运行 ScreenAim --calibrate --serve 产生数据")
    return files[-1]


def run_lengths(mask: np.ndarray) -> np.ndarray:
    """连续 True 段的长度序列。"""
    if not mask.any():
        return np.array([])
    edges = np.diff(mask.astype(int))
    starts = np.concatenate([[0], np.where(edges == 1)[0] + 1])
    ends = np.concatenate([np.where(edges == -1)[0] + 1, [len(mask)]])
    if not mask[0]:
        starts = starts[1:]
    if not mask[-1]:
        ends = ends[:-1]
    return ends - starts


csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else pick_csv()
out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else \
    ROOT / "scenes" / (csv_path.stem + "_jitter.png")

df = pd.read_csv(csv_path)
if df.empty:
    sys.exit(f"{csv_path} 没有数据行")
has_quality = "quality" in df.columns

t0 = df["timestamp"].iloc[0]
df["t"] = df["timestamp"] - t0
ok_mask = df["x"].notna().to_numpy()
dt = df["timestamp"].diff().to_numpy().copy()
dt[0] = np.nan

# ---- 连续性指标 ----
dt_valid = dt[~np.isnan(dt)]
gaps = dt_valid[dt_valid > GAP_S]
bursts = dt_valid[dt_valid < BURST_S]
ok_rate = ok_mask.mean() * 100
noid_runs = run_lengths(~ok_mask)

# ---- 位移（仅连续有效段内计算：断流前后的两点不算相邻帧）----
df["disp"] = np.nan
disp = np.hypot(df["x"].diff(), df["y"].diff())
disp[(~ok_mask) | (~np.roll(ok_mask, 1))] = np.nan   # 任一端无效则不计
disp[0] = np.nan
# 断流后首帧也不算相邻（dt 超门限时位移无时间意义）
disp[dt > GAP_S] = np.nan
df["disp"] = disp

# ---- 静止段：滚动位移中位数 < 阈值（对跳变离群免疫）----
roll_med = df["disp"].rolling(STILL_WIN, center=True, min_periods=5).median()
still = (roll_med < STILL_DISP_PT).fillna(False).to_numpy()

# ---- 跳变事件：绝对下限 + 滚动 MAD 相对门限 ----
mad = (df["disp"] - roll_med).abs().rolling(STILL_WIN, center=True,
                                            min_periods=5).median()
jump_thresh = np.maximum(JUMP_MIN_PT, JUMP_MAD_K * mad)
jump_mask = (df["disp"] > jump_thresh).fillna(False)
jumps = df[jump_mask]
# 静止段统计剔除跳变帧：RMS 对离群极敏感（实测静止段内个别跳变可把 RMS 从 ~2pt 拉到 60+pt）
still_disp = df["disp"][still & ~jump_mask.to_numpy()].dropna()

# ---- 控制台指标表 ----
def pct(s, q):
    return float(np.nanpercentile(s, q)) if len(s) else float("nan")

print(f"== {csv_path.name} ==")
print(f"帧数 {len(df)}  时长 {df['t'].iloc[-1]:.0f}s  有效率 {ok_rate:.1f}%  "
      f"quality列 {'有' if has_quality else '无（旧客户端）'}")
print("-- 连续性（dt = Mac 到达间隔，含网络抖动）--")
print(f"dt ms: p50={pct(dt_valid*1000,50):.0f} p95={pct(dt_valid*1000,95):.0f} "
      f"p99={pct(dt_valid*1000,99):.0f} max={np.nanmax(dt_valid)*1000:.0f}")
print(f"断流(>{GAP_S*1000:.0f}ms): {len(gaps)} 次，累计 {gaps.sum():.1f}s  "
      f"网络攒批(<{BURST_S*1000:.0f}ms): {len(bursts)/max(len(dt_valid),1)*100:.0f}%")
if len(noid_runs):
    print(f"无瞄准点连段: {len(noid_runs)} 段，最长 {noid_runs.max()} 帧")
print("-- 静止段抖动（帧间位移，pt）--")
if len(still_disp):
    print(f"静止帧 {still.sum()}（{still.mean()*100:.0f}%）  "
          f"RMS={np.sqrt((still_disp**2).mean()):.2f}  p50={pct(still_disp,50):.2f}  "
          f"p95={pct(still_disp,95):.2f}")
else:
    print("未检出静止段（全程运动或数据太短）")
print("-- 跳变事件 --")
print(f"{jump_mask.sum()} 次（>{JUMP_MIN_PT:.0f}pt 且 > {JUMP_MAD_K:.0f}×滚动MAD）")
for _, r in jumps.nlargest(5, "disp").iterrows():
    print(f"  t={r['t']:.1f}s disp={r['disp']:.0f}pt markers={int(r['markers'])}")
if has_quality:
    print("-- 分 quality 帧间位移 p95（pt）--")
    for q, g in df.groupby(df["quality"].fillna("(空)")):
        d = g["disp"].dropna()
        if len(d):
            print(f"  {q}: n={len(d)} p50={pct(d,50):.2f} p95={pct(d,95):.2f}")

# ---- 四面板图 ----
fig, axes = plt.subplots(2, 2, figsize=(13, 9))

# 面板 1：dt 分布直方图（对数横轴，攒批/正常/断流三带）
ax = axes[0][0]
bins = np.logspace(-3, 3, 60)
ax.hist(dt_valid[dt_valid > 0], bins=bins, color="tab:blue", alpha=0.8)
ax.axvline(GAP_S, color="tab:red", ls="--", lw=1, label=f"断流门限 {GAP_S*1000:.0f}ms")
ax.axvline(BURST_S, color="tab:orange", ls="--", lw=1, label=f"攒批门限 {BURST_S*1000:.0f}ms")
ax.set_xscale("log")
ax.set_xlabel("到达间隔 dt（秒，对数轴）")
ax.set_ylabel("帧数")
ax.set_title(f"连续性：dt 分布（攒批 {len(bursts)/max(len(dt_valid),1)*100:.0f}% / "
             f"断流 {len(gaps)} 次）")
ax.legend(fontsize=9)

# 面板 2：帧间位移时间线（对数纵轴），静止段绿底、跳变红叉
ax = axes[0][1]
ax.plot(df["t"], df["disp"], lw=0.6, color="tab:blue", alpha=0.7)
still_grp = pd.Series(still).astype(int).diff()
s_starts = np.where(still_grp == 1)[0]
s_ends = np.where(still_grp == -1)[0]
if still[0]:
    s_starts = np.concatenate([[0], s_starts])
if still[-1] and len(s_ends) < len(s_starts):
    s_ends = np.concatenate([s_ends, [len(still) - 1]])
for s, e in zip(s_starts, s_ends):
    ax.axvspan(df["t"].iloc[s], df["t"].iloc[e], color="tab:green", alpha=0.12)
if not jumps.empty:
    ax.scatter(jumps["t"], jumps["disp"], marker="x", color="tab:red", s=40,
               zorder=5, label=f"跳变（{len(jumps)} 次）")
    ax.legend(fontsize=9)
ax.set_yscale("log")
ax.set_xlabel("时间（秒）")
ax.set_ylabel("帧间位移（pt，对数轴）")
ttl = "抖动：帧间位移时间线（绿底 = 静止段）"
if len(still_disp):
    ttl += f"　静止 p95={pct(still_disp,95):.2f}pt"
ax.set_title(ttl)

# 面板 3：轨迹 + 跳变标记
ax = axes[1][0]
okdf = df[df["x"].notna()]
if not okdf.empty:
    ax.plot(okdf["x"], okdf["y"], lw=0.5, color="tab:blue", alpha=0.3)
    sc = ax.scatter(okdf["x"], okdf["y"], c=okdf["t"], cmap="viridis", s=8)
    fig.colorbar(sc, ax=ax, label="时间（秒）")
    if not jumps.empty:
        ax.scatter(jumps["x"], jumps["y"], marker="x", color="tab:red", s=60,
                   zorder=5, label="跳变落点")
        ax.legend(fontsize=9)
ax.invert_yaxis()
# 轨迹视野按有效点的稳健分位数裁剪：跳变离群点（实测可上万 pt）会把真实轨迹
# 压成一条细带；跳变落点数值已在控制台列出，图上裁掉不损失信息
if not okdf.empty:
    x0, x1 = np.percentile(okdf["x"], [0.5, 99.5])
    y0, y1 = np.percentile(okdf["y"], [0.5, 99.5])
    mx, my = (x1 - x0) * 0.1 + 10, (y1 - y0) * 0.1 + 10
    ax.set_xlim(x0 - mx, x1 + mx)
    ax.set_ylim(y1 + my, y0 - my)   # 已 invert，下限在上
ax.set_aspect("equal", adjustable="box")
ax.set_xlabel("x（点）")
ax.set_ylabel("y（点）")
ax.set_title("瞄准点轨迹（屏幕逻辑坐标，左上原点）")

# 面板 4：最长静止段的 x/y 功率谱（高频 = 识别噪声，低频 = 真实漂移/手抖）
ax = axes[1][1]
if len(s_starts):
    i = int(np.argmax(s_ends - s_starts))
    seg = df.iloc[s_starts[i]:s_ends[i]].dropna(subset=["x"])
    if len(seg) >= 64:
        segdt = np.diff(seg["timestamp"])
        fs = 1.0 / np.median(segdt[segdt > 1e-4]) if (segdt > 1e-4).any() else 15.0
        for col, c in (("x", "tab:blue"), ("y", "tab:orange")):
            v = seg[col].to_numpy() - seg[col].mean()
            f = np.fft.rfftfreq(len(v), 1 / fs)
            p = np.abs(np.fft.rfft(v * np.hanning(len(v)))) ** 2
            ax.plot(f[1:], p[1:], color=c, lw=1, label=f"{col} 功率谱")
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlabel("频率（Hz）")
        ax.set_ylabel("功率")
        ax.legend(fontsize=9)
        ax.set_title(f"最长静止段功率谱（{len(seg)} 帧 @≈{fs:.0f}Hz）："
                     "高频分量 = 识别噪声")
    else:
        ax.text(0.5, 0.5, "最长静止段不足 64 帧，无法做谱分析",
                ha="center", va="center", transform=ax.transAxes)
else:
    ax.text(0.5, 0.5, "无静止段", ha="center", va="center", transform=ax.transAxes)

fig.suptitle(f"白点连续性与抖动分析 — {csv_path.name}", fontsize=13)
fig.tight_layout()
fig.savefig(out_path, dpi=170, bbox_inches="tight")
print(f"已保存: {out_path}")
