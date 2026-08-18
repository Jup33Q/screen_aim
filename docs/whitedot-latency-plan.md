# 白点显示滞后优化方案

> 日期：2026-08-17 · 触发问题：iPhone 识别与 Mac 白点显示之间有可感知的较长滞后
>
> 前置：边角定位修复第一批（WP1 仿射兜底 + WP3 滤波增强，ADR-013/014）已落地验收。
> 优先级继承定位优化方案：**识别质量 > 传输速度 > 其他**——本方案全部是显示/传输侧，
> 不得劣化静止 σ 与跳变门行为。

---

## 0. 滞后预算（白点链路逐项拆解）

白点走 localAim 上报路径（iPhone 本机识别 → TLV type 1 控制帧 → Mac `dotFilter` → 摆点），
与 `--aim-cursor` 光标路径（Mac 侧视频帧识别）无关。运动中的端到端滞后 ≈ 以下各项之和：

| # | 环节 | 量级 | 性质 | 代码锚点 |
|---|---|---|---|---|
| 1 | 15fps 识别/上报节奏 | ≤66ms（结构性下限） | 帧曝光完成后才识别，位置新鲜度被帧率钉死 | `CameraStreamer.captureOutput` |
| 2 | iPhone 识别段 One Euro 跟踪滞后 | 速度×τ，慢速段最明显 | 消抖固有代价（beta 高速段救回） | `AimCoastFilter`（daily: minCutoff 1.0/β0.5） |
| 3 | 检测耗时 | ~10ms | 可测（CSV `detect_ms` 列） | `localizeFrame` |
| 4 | TLV 单连接排队 + WiFi | ~10–30ms | 200B 控制帧排在已入队的 ~100KB JPEG 后出队；noDelay 已开 | `TLVTransport.sendIdempotent` |
| 5 | Mac 显示段滤波滞后 | WP3.3 前与 #2 同量级（双倍消抖），现已大幅减轻 | 显示段只做轻插值（minCutoff 2.0/β1.0） | `Calibrator.dotFilter` |
| 6 | 白点"到达才摆" | ≤66ms + 阶梯感 | 两次上报之间白点原地不动，离散步进被读成"拖" | main.swift localAim 分支 |
| 7 | 主线程派发 + AppKit 一帧 | ~16ms | 显示刷新 | — |

**结论**：滞后 ≈ 100–150ms 基线 + 滤波滞后。可压缩空间最大的是 #6（纯显示侧，零风险），
其次是 #5 已修、#1 需提频评估，#4 收益最小工程最大。

已排除的嫌疑：iPhone 端 `localizeFrame` 在同串行队列里先于 JPEG 编码执行
（识别结果不等编码）；滤波是纯 CPU 计算，不上行任何额外数据。

---

## 1. WP-L1 · 60Hz 外推显示（最高性价比，先做）

### 机制

Mac 显示段加 60Hz 显示定时器：两次 localAim 到达之间，按 `AimCoastFilter` 的
低通速度对**白点显示位置**做死推算（dead reckoning）外推摆点：

- `AimCoastFilter` 新增只读接口 `displayExtrapolation(at t:) -> CGPoint?`：
  `lastOut + 衰减速度 × Δt`（衰减沿用 `coastHalfLife`），**不改滤波状态**；
  外推时距内部封顶（≤120ms），封顶后原地保持——新样本到达时 `update()` 输出
  权威位置，外推只填空窗。
- 与断流滑行正交：滑行预算仍由 `update(raw: nil)` 的帧计数控制；定时器只在
  白点可见时重摆（`dot.isHidden == false`），滑行耗尽隐藏后定时器自然停摆。
- 只动 Mac 显示段（main.swift Calibrator），不改 UI 布局/交互、不改协议、
  iPhone 零改动；`--aim-cursor` 路径不受影响。

### 验收

- `--filter-self-test` 加子测试：匀速运动样本序列后，`displayExtrapolation`
  在 +33ms/+66ms 的外推点与真值轨迹误差 < 1pt（确定性合成信号）；
  静止样本外推不动点（漂移 < 0.1pt）。
- `swift build && swift run ScreenAim --self-test` 无回归；iOS 无改动不跑 xcodebuild。
- 真机冒烟（主观 + CSV）：横扫时白点阶梯感消失、贴手度明显提升；
  localaim CSV 数据不变（只动显示端）作为对照确认无识别侧副作用。

### 收益估算

消除 #6（≤66ms 保持滞后 + 阶梯感），运动中感知滞后从 ~100–150ms 降到 ~50–80ms。
改动量：ScreenAimCore 一个只读方法 + Calibrator 一个定时器，约 60 行。

---

## 2. WP-L2 · 识别/上报提频评估（15Hz → 30Hz，评估先行，不达标不上）

### 先查再改

1. 确认真机链路真实帧率：相机实际输出 fps（`applyDeviceSettings` 手动曝光
   1/120s 对帧率下限的约束）、`localizeFrame` ≥10ms 节流的实际触发率、
   localaim CSV 相邻行时间戳差分布（现状应 ≈66ms）。
2. 30Hz 成本实测：`detect_ms` 是否随负载上升（检测 ~10ms × 30fps ≈ 30% CPU 一路）、
   发热/耗电、视频推流是否被挤（同队列 JPEG 编码）。

### A/B 门槛

同轨迹 15Hz vs 30Hz 各录 3 分钟 localaim CSV：横扫滞后（轨迹相位差）目标 -40% 以上；
静止 σ 不劣化；`detect_ms` p95 不明显上升；视频流帧率不掉。全达标才把默认节流改 30Hz，
否则保持 15Hz 并记录结论。

---

## 3. WP-L3 · UDP 结果通道（暂缓）

protocol.md §9 预留。只省 #4 的 TCP 排队 ~10–30ms，收益最小、工程最大
（新通道的丢包/乱序语义、双端实现、回归面）。等 WP-L1/L2 落地后若滞后仍不可接受
再立项，设计底稿见 docs/transport-26-plan.md。

---

## 4. 执行顺序与总验收

1. **WP-L1**（60Hz 外推显示）— 零风险先做
2. **WP-L2**（提频评估）— 先测后改，A/B 达标才动默认值
3. **WP-L3**（UDP）— 暂缓

每个 WP 完成后必跑：`swift build && swift run ScreenAim --self-test --filter-self-test`；
新增 ADR 按 docs/decisions.md 实际最大编号顺延（当前最新 ADR-014，预计从 ADR-015 起）；
docs/modules.md / architecture.md 同步。

## 5. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 外推过头（网络延迟突增时白点冲过真实位置） | 白点位置短暂超前 | 时距封顶 120ms + 速度衰减；新样本到达即校正 |
| 显示定时器与到达更新竞争 | 白点抖动 | 全部主线程执行（Calibrator 约定），单线程无竞争 |
| 30Hz 提频拉高 CPU/发热，检测反而掉帧 | 识别质量劣化 | WP-L2 是评估门，不达标不动默认值 |
