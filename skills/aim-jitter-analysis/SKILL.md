---
name: aim-jitter-analysis
description: ScreenAim 白点（瞄准点）二维坐标的连续性与抖动分析。当用户要分析 localaim_*.csv 数据、量化白点"静止稳不稳/甩动跟不跟手"、定位抖动根因（识别噪声/单应跳变/网络攒批/断流滑行）、对比滤波预设（stable/daily/fast）或 --dot-* 旋钮效果、验证 TLV 链路消息时效性时使用。覆盖数据坑（到达时刻≠采集时刻、网络攒批、跳变离群、旧文件无 quality 列）、连续性/静止抖动/跳变/频谱四类指标、分析脚本与滤波调参的联动。
---

# 白点连续性与抖动分析（localAim CSV）

数据源：`scenes/localaim_*.csv`（Mac 端每条 localAim 上报追加一行，main.swift `logLocalAim`）。
列：`timestamp,markers,ids,x,y,detect_ms,src[,quality]`（quality 为 WP1 新增，旧文件没有）。
配套：基础可视化 `tools/plot_localaim.py`（成功率时间线 + 轨迹）；本 skill 的
`scripts/jitter_report.py`（连续性 + 抖动 + 跳变 + 功率谱四面板）。
滤波调参对照：[docs/aim-filter-tuning.md](../../docs/aim-filter-tuning.md)。

## 数据坑（分析前必须知道，脚本已处理）

| 坑 | 影响 | 处理 |
|---|---|---|
| `timestamp` 是 **Mac 到达时刻**，不是手机采集 PTS | dt 分布混入网络/调度抖动，不能当相机帧间隔 | dt 只用于"链路连续性"指标；频谱采样率用段内 dt 中位数现估 |
| 同一 timestamp 连出多条（实测约 1/3） | 网络攒批到达，dt≈0 | 记攒批率；dt<5ms 不参与除法 |
| `x,y` 为空 = 无瞄准点帧 | 断流段两端坐标差无时间意义 | 位移只在连续有效段内算；断流后首帧不计 |
| 跳变离群（单应翻转/标记掉检，实测可达上万 pt） | RMS 被拉爆、轨迹图被压扁 | 跳变帧只标记不剔除；静止段判定用滚动中位数免疫离群；RMS 统计剔除跳变帧 |
| 会话中途长时间挂起（实测单次 453s） | max dt 无分析价值 | 断流按 >500ms 切段，逐段看 |
| 旧 CSV 无 `quality` 列 | 无法分层 | 脚本自动降级；分层分析要求新客户端数据 |

## 快速开始

```bash
python skills/aim-jitter-analysis/scripts/jitter_report.py            # 最新会话
python skills/aim-jitter-analysis/scripts/jitter_report.py scenes/localaim_XXX.csv
```

控制台出指标表，同目录存 `*_jitter.png` 四面板图：
dt 分布 / 帧间位移时间线（绿底=静止段，红叉=跳变）/ 轨迹 / 最长静止段功率谱。

## 四类指标怎么读

详细定义与门槛取值见 [references/metrics.md](references/metrics.md)。

1. **连续性**：dt p50/p95/p99、断流次数与累计时长、攒批率、无瞄准点连段长度。
   回答"白点会不会卡住/消失"。名义上报 15–30Hz，dt p95 应 < 150ms；
   攒批率高 = TLV 链路排队（联动 tlv-blocking-optimization-plan）。
2. **静止段抖动**：帧间位移 RMS / p95（剔除跳变帧）。回答"静止时纹丝不动吗"。
   对应调参指南的 `--dot-min-cutoff`；p95 > 5pt 说明消抖不足或识别噪声过大。
3. **跳变事件**：位移 > 20pt 且 > 8×滚动 MAD。逐条列时刻/幅度/markers 数。
   markers=4–5 的万 pt 级跳变 = 4 标记单应退化翻转（冗余 8 标记的意义）；
   密集小跳变 = gateK 该收紧或掉检恢复追平。对应 `--dot-gate-k`。
4. **功率谱**（最长静止段 x/y）：高频（>3Hz）= ArUco 识别噪声，靠 minCutoff 压；
   低频（<0.5Hz）= 真实漂移/手抖/滑行衰减，滤波压不掉，属信号不是噪声。

## 分析结论 → 调参动作映射

| 现象 | 根因方向 | 动作 |
|---|---|---|
| 静止 p95 高 + 功率谱高频肥 | 识别噪声透出 | minCutoff 往低调 / 预设升 stable |
| 横扫拖、慢移滞后 | minCutoff 过低或 beta 过低 | 预设降 fast 或 `--dot-beta` 调高 |
| 万 pt 级跳变，markers=4–5 | 4 标记单应退化 | 不是滤波问题——查标记遮挡/反光，RANSAC 内点数 |
| 密集跳变集中在掉检恢复后 | 恢复追平步进 | `--dot-gate-k` 收紧，或查 coast 段质量 |
| 攒批率飙升 + dt p95 恶化 | 链路排队（采集回传争用/弱网） | 联动 docs/tlv-blocking-optimization-plan，不是滤波问题 |
| quality=coast 段也有抖动 | 速度外推不稳 | `--dot-coast-frames` 调低或查 coast 半衰期 |

## 对比实验流程（A/B 预设/旋钮）

1. 固定动作脚本：静止 10s → 慢速画圆 → 快速横扫 ×3 → 遮挡单角 5s → 恢复。
2. 每档预设跑一次（`--filter-preset stable|daily|fast`），各生成一个 localaim CSV。
3. 分别跑 `jitter_report.py`，对比：静止 p95、跳变次数、coast 段位移 p95、dt 分布。
4. 滞后（lag）无法从 CSV 直接算（无地面真值通道）——用
   `swift run ScreenAim --filter-self-test` 的合成信号拿确定性滞后数据。

## 边界（什么时候不用本 skill）

- 要看的是 Mac 端视频帧识别管线（ScreenSampler）而不是手机本机识别上报 —— 那条链路没有 CSV 落盘，只有 stdout 日志。
- 识别率/检出标记数的整体趋势 —— `tools/plot_localaim.py` 更直接。
- 实时盯盘 —— 用 Canvas 的「AimPhone 识别质量 · localAim」Widget，本 skill 是离线分析。
