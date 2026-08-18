# 白点显示滞后优化 · kimi cli 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 分次发更稳：先发「第一批：WP-L1」（纯显示侧，零风险），验收通过后发「第二批：WP-L2 提频评估」。
> 方案全文（滞后预算表、机制分析、验收门槛）见 docs/whitedot-latency-plan.md。
> 前置：边角定位修复第一批（WP1/WP3，ADR-013/014）已落地——AimCoastFilter 双端共用、
> 滤波分层、--filter-self-test 均已存在。
> 注意：新增 ADR 动手前以 docs/decisions.md 实际最大编号为准顺延（当前最新 ADR-014，预计从 ADR-015 起）。

---

## 第一批提示词（WP-L1 · 60Hz 外推显示）

```text
# 任务：ScreenAim 白点滞后优化 第一批（WP-L1 · 60Hz 外推显示）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
批次：第一批 = WP-L1（Mac 显示段 60Hz 死推算外推摆点）。
第二批（WP-L2 提频评估）等我确认后再做；WP-L3（UDP）暂缓不动。

## 动手前必读（按顺序，全部读完再写代码）
1. docs/whitedot-latency-plan.md —— 本次任务书：§0 滞后预算表、§1 WP-L1、§5 风险登记
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/architecture.md —— 线程模型与坐标系约定（含 ADR-014 滤波分层一节）
4. docs/aim-filter-tuning.md —— 滤波双段分工与参数语义
5. 现状代码：Sources/ScreenAimCore/AimCoastFilter.swift（coastVel/lastOut/lastT 状态、
   coastStep 速度衰减外推）、Sources/ScreenAim/main.swift Calibrator 的 dotFilter 与
   localAim 分支白点摆点（aimDot，y 翻转 + 屏内钳制）

## 执行内容（本批次）
严格按方案 §1 执行：
- AimCoastFilter 新增只读接口 displayExtrapolation(at t:) -> CGPoint?：
  lastOut + 衰减速度 × Δt（衰减沿用 coastHalfLife），不修改任何滤波状态；
  外推时距内部封顶 ≤120ms，封顶后返回原地保持点；滤波器未初始化/已隐藏语义返回 nil
- Calibrator 起 60Hz 显示定时器（主 runloop，符合既有主线程约定）：
  白点可见（dot.isHidden == false）且 dotFilter 有状态时，把 aimDot 重摆到外推点
  （沿用 y 翻转 + 屏内钳制的同一套坐标换算，不要复制出第二份——抽成共用小函数）；
  白点隐藏时定时器空转直接返回
- 断流滑行语义不变：滑行预算仍只由 update(raw: nil) 帧计数控制，
  定时器只填两次事件之间的显示空窗；localAim 到达帧的 update() 输出仍是权威位置
- --filter-self-test 加子测试：匀速运动样本后 +33ms/+66ms 外推点与真值轨迹误差 < 1pt；
  静止样本外推漂移 < 0.1pt；超过 120ms 时距外推值等于封顶点

## 硬约束
- 不改 UI 布局与交互（aimDot 之外的视觉样式、ContentView 一律不动）；不改协议；
  iPhone 零改动；注释全中文，新文件带 L0 文件头；改行为同步改注释
- 只动 Mac 显示段；--aim-cursor 光标路径不受影响（它走 Mac 侧视频帧识别）
- 完成后必须跑：
    swift build && swift run ScreenAim --self-test && swift run ScreenAim --filter-self-test
  iOS 无改动，不需要 xcodebuild
- 一个 git commit，message 写明验收结果

## 验收门槛
- --filter-self-test 全部子测试通过（含新增外推子测试），--self-test 无回归
- 真机冒烟：横扫时白点阶梯感消失、明显更贴手；localaim CSV 与改动前同轨迹对比
  无差异（只动显示端的旁证），结果写进验收小结

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. 验收小结（合成子测试数值 + 真机主观/CSV 对照，注明机型/分辨率条件）
3. 新增 ADR（60Hz 外推显示一条，编号按 decisions.md 顺延）；
   docs/modules.md、docs/architecture.md 同步
4. 未决风险与第二批（WP-L2 提频评估）的准备情况
```

---

## 第二批提示词（WP-L2 · 识别/上报提频评估，第一批验收通过后再发）

```text
# 任务：ScreenAim 白点滞后优化 第二批（WP-L2 · 15Hz → 30Hz 提频评估）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：WP-L1（60Hz 外推显示）已完成并验收。
动手前重读 docs/whitedot-latency-plan.md §2、docs/comment-style.md、
docs/protocol.md §7；现状锚点：ios/AimPhone/CameraStreamer.swift（applyDeviceSettings
手动曝光 1/120s、captureOutput 里 ≥10ms 的 localize 节流、15fps 推流节流 lastSendTime）、
tools/plot_localaim.py。

## 执行内容
严格按方案 §2「先查再改」执行：
1. 先出调查报告（不改行为）：相机实际输出 fps、localize 实际触发率、
   localaim CSV 相邻行时间戳差分布、detect_ms 现状 p50/p95；
   评估 30Hz 识别的 CPU/发热成本与对同队列 JPEG 推流的影响
2. 报告确认后再做 A/B：识别/上报节流改 30Hz（推流仍 15fps 不变），
   同轨迹 15Hz vs 30Hz 各录 3 分钟 localaim CSV，
   tools/plot_localaim.py + 轨迹相位差分析横扫滞后
3. A/B 门槛：横扫滞后 -40% 以上；静止 σ 不劣化；detect_ms p95 不明显上升；
   视频流帧率不掉。全达标才把 30Hz 设为默认，否则保持 15Hz 并记录结论

## 硬约束与验收（同第一批规则，另加）
- iOS 侧有改动，必须跑：
    cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
- 提频是可逆开关（CLI/常量），不是写死；不达标回退默认 15Hz
- 一个 git commit，message 写明 A/B 结论

## 交付物
1. 帧率链路调查报告（实测数据）
2. A/B 对比结论（横扫滞后、静止 σ、detect_ms、视频帧率）与去/留判定
3. 新增 ADR（提频结论：判定依据与实测数字，编号按 decisions.md 顺延）；
   docs/protocol.md（若上报节奏语义变化）、docs/aim-filter-tuning.md（时间轴假设）同步
```
