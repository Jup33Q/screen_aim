#!/usr/bin/env python3
"""可视化 scenes/localaim_*.csv（ScreenAim Mac 端记录的手机本机识别上报流）。

用法:
    python tools/plot_localaim.py [csv路径] [输出png路径]

- 不带参数时自动取 scenes/ 下最新的 localaim_*.csv
- 输出双面板图：
  上：识别成功率时间线（滚动窗口）+ 每帧检出标记数
  下：瞄准点轨迹（屏幕坐标系，左上角原点，y 轴翻转）
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # workspace 根
sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))  # daimon_runtime

from daimon_runtime import setup_plot
import numpy as np
import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt

setup_plot()

ROOT = Path(__file__).resolve().parent.parent

def pick_csv() -> Path:
    files = sorted((ROOT / "scenes").glob("localaim_*.csv"),
                   key=lambda p: p.stat().st_mtime)
    if not files:
        sys.exit("scenes/ 下没有 localaim_*.csv，先运行 ScreenAim --calibrate --serve 产生数据")
    return files[-1]

csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else pick_csv()
out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else \
    ROOT / "scenes" / (csv_path.stem + "_report.png")

df = pd.read_csv(csv_path)
if df.empty:
    sys.exit(f"{csv_path} 没有数据行")

t0 = df["timestamp"].iloc[0]
df["t"] = df["timestamp"] - t0          # 相对秒
df["ok"] = df["x"].notna()              # 有坐标 = 集齐 4 角
# 滚动成功率：约 10 秒窗口（2Hz -> 20 条），不足时降级 min_periods
win = max(5, min(20, len(df) // 2))
df["ok_rate"] = df["ok"].rolling(win, min_periods=1).mean() * 100

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 8), height_ratios=[1, 1.2])

# --- 面板 1：成功率时间线 + 检出数 ---
sns.lineplot(data=df, x="t", y="ok_rate", ax=ax1, color="tab:blue", lw=1.8,
             label=f"识别成功率（{win} 帧滚动窗口）")
ax2t = ax1.twinx()
sns.scatterplot(data=df, x="t", y="markers", ax=ax2t, color="tab:orange",
                alpha=0.35, s=14, label="每帧检出标记数")
ax2t.set_ylim(-0.3, 4.3)
ax2t.set_yticks(range(5))
ax2t.set_ylabel("检出标记数")
fail = df[~df["ok"]]
if not fail.empty:
    ax1.scatter(fail["t"], [0] * len(fail), marker="x", color="tab:red",
                s=30, zorder=5, label="未识别帧")
ax1.set_ylim(-5, 105)
ax1.set_ylabel("成功率 (%)")
ax1.set_xlabel("时间（秒，相对会话开始）")
ax1.set_title(f"手机端识别质量时间线 — {csv_path.name}（共 {len(df)} 帧，"
              f"整体成功率 {df['ok'].mean() * 100:.1f}%）")
h1, l1 = ax1.get_legend_handles_labels()
h2, l2 = ax2t.get_legend_handles_labels()
ax1.legend(h1 + h2, l1 + l2, loc="lower right", fontsize=9)

# --- 面板 2：瞄准点轨迹（屏幕坐标，左上原点） ---
ok = df[df["ok"]]
if not ok.empty:
    # 按时间先后连线，颜色从浅到深表示时间推进
    ax2.plot(ok["x"], ok["y"], color="tab:blue", alpha=0.35, lw=1)
    sc = ax2.scatter(ok["x"], ok["y"], c=ok["t"], cmap="viridis", s=18)
    fig.colorbar(sc, ax=ax2, label="时间（秒）")
    ax2.set_title(f"瞄准点轨迹（{len(ok)} 个有效点）— 屏幕逻辑坐标")
else:
    ax2.text(0.5, 0.5, "本会话没有任何成功识别帧", ha="center", va="center",
             transform=ax2.transAxes, fontsize=13, color="tab:red")
    ax2.set_title("瞄准点轨迹 — 屏幕逻辑坐标")
ax2.invert_yaxis()          # 屏幕坐标左上角原点：y 向下
ax2.set_xlabel("x（点）")
ax2.set_ylabel("y（点）")
ax2.set_aspect("equal", adjustable="box")

fig.tight_layout()
fig.savefig(out_path, dpi=180, bbox_inches="tight")
print(f"已保存: {out_path}")
print(f"帧数={len(df)} 成功率={df['ok'].mean() * 100:.1f}% "
      f"平均检出={df['markers'].mean():.2f}/4")
