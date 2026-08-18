# 更新速率优化方案 · 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 分次发更稳：先发「第一批：P0 + P1」，验收通过后发「第二批：P2」，
> 再发「第三批：P3 → P4」（P3 是 bench 门控，不过门不合入；P4 可选）。
> 方案本体：[update-rate-optimization-plan.md](update-rate-optimization-plan.md)。

---

## 第一批提示词（P0 Release 构建固化 + P1 无标记自适应降频）

```text
# 任务：ScreenAim 更新速率优化 第一批（P0 + P1）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
背景：2026-08-18 实测——Debug 构建上真机导致手机端 detect_ms 从 8–15ms 涨到 640ms，
localAim 从 8–15Hz 掉到 1.5Hz（数据见 plan §0.1）。网络层已排查健康，不要动网络代码。

## 动手前必读（按顺序，全部读完再写代码）
1. docs/update-rate-optimization-plan.md —— 本次任务书：§0 根因、§1/§2 改动清单、§6 验收方法
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/architecture.md —— 线程模型（新代码不得违反）
4. docs/decisions.md —— ADR-009/013/017（上报频率、滑行预算、fast 通道语义）

## 执行内容（本批次）
严格按 plan §1、§2 执行：
- P0：ios/project.yml 用 XcodeGen scheme 把 Run 的 Build Configuration 固定为
  Release（xcodegen generate 后不丢失）；docs/development.md 补排错项
  「detect_ms 突然涨几十倍 → 检查是否 Debug 构建上机」，根 README 手机端小节
  注明日常真机验证用 Release
- P1：CameraStreamer.swift 识别间隔改两档（满速 1/15s / 降频 0.3s，常量集中
  文件头部）；连续 0 检出满 10 次进降频档，任一帧检出 >0 立即回满速；
  安全性论证按 plan §2.3 写 NOTE（降频门槛 10 > 滑行预算 5，不改白点滑行语义）；
  扫码分支、JPEG 发送、captureRecorder 触发逻辑一律不动

## 硬约束
- 不改 TLV 线上格式；localAim 字段只加不删；不改 UI 布局与交互
- 注释全中文，改行为同步改注释；像素数据不进主线程
- 每 Phase 完成后必须跑：
    swift build && swift run ScreenAim --self-test
    cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj \
      -scheme AimPhone -destination 'generic/platform=iOS' build
  （签名失败可接受，编译错误不可接受）
- P0 额外验证：xcodebuild -showBuildSettings 确认 Run 配置 SWIFT_OPTIMIZATION_LEVEL=-O
- 每 Phase 一个 git commit，message 写明验收结果

## 验收门槛（不过门槛不得进入下一 Phase）
- P0：真机 Release 部署后按 plan §6 跑 ≥3 分钟会话：detect_ms 中位 ≤ 20ms，
  localAim 速率 ≥ 8Hz（分析最新 scenes/localaim_*.csv，注明构建配置）
- P1：镜头移开屏幕 5 秒后 LOCALAIM 日志间隔降到 ~300ms；移回 1 秒内恢复满速；
  白点（含边角 3 标记仿射兜底）行为与改动前一致

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. P0/P1 验收小结（实测值 vs 门槛，注明机型/系统/标记尺寸/构建配置）
3. docs/development.md、根 README 同步；modules.md CameraStreamer 条目补两档说明
4. 未决风险与第二批（P2 队列解耦）的准备情况
```

---

## 第二批提示词（P2 识别挪出采集串行队列）

```text
# 任务：ScreenAim 更新速率优化 第二批（P2 识别解耦）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：P0/P1 已完成并验收。动手前重读 docs/update-rate-optimization-plan.md §3、
docs/comment-style.md、docs/architecture.md 线程模型；对照 Mac 端
Sources/ScreenAim/main.swift 的 frameInFlight busy 闸门段（同构参考实现）。

## 执行内容
严格按 plan §3 执行，全部改动在 ios/AimPhone/CameraStreamer.swift：
1. 新增 localizeQueue（"aimphone.localize"），localizeFrame 改为异步执行
2. busy 闸门：NSLock + localizeInFlight，处理中时新识别请求直接丢弃不排队
   （NOTE 注明与 Mac 端 frameInFlight 的对应关系）
3. CVPixelBuffer 跨队列 retain/release，WARNING 注释帧池泄漏风险
4. captureRecorder.record 调用随迁；录制期 PNG 编码占用 localizeQueue 的
   取舍按 plan §3.4 写 NOTE
5. JPEG 编码/发送/framesSent、未连接扫码分支留在 videoQueue 不动

## 硬约束与验收（同第一批规则，另加）
- 每 Phase 后：swift build && swift run ScreenAim --self-test；
  iOS 改动后 xcodegen generate + xcodebuild 编译必须过
- 真机 Release：视频有效帧率 ≥ 14fps，localAim 到达间隔 p50 ≤ 130ms
- Debug 构建反向验证一次：localAim 降速但视频帧率基本不受影响（解耦的直接
  证据），验证完切回 Release，数据写进验收小结
- 内存观察 3 分钟平坦（无帧池泄漏）
- 一个 git commit，message 写明验收结果

## 交付物
改动文件清单、验收小结（含 Debug 反向验证数据）、新增 ADR-018（手机端识别
调度：Release 固化 + 队列解耦 + 无检出降频，写明 2026-08-18 实测依据）、
docs/architecture.md 线程模型与 docs/modules.md 同步。
```

---

## 第三批提示词（P3 降采样 bench → P4 30fps 可选）

```text
# 任务：ScreenAim 更新速率优化 第三批（P3 bench 门控 → P4 可选）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：P0–P2 已完成并验收。动手前重读 docs/update-rate-optimization-plan.md §4/§5、
docs/comment-style.md、docs/positioning-optimization-plan.md 中 Phase 1 的 bench 方法
（tools/make_bench_scenes.py + --replay A/B）。

## 执行内容
- P3：MarkerDetector.swift 加 inputScale（1/2，灰度阶段隔像素采样），坐标 ×scale
  映射回原系；minSide/minCellGap/亚像素剖面半径等像素参数集中按 scale 折算
  （WARNING 注释）；亚像素精化是否保留全分辨率执行由 bench 结果决定。
  先跑 --replay A/B 拿数据——不达验收门就不合入真机默认，停下来汇报。
- P4（P3 有结论后再做，且仅当我确认）：frameInterval 1/15 → 1/30，
  protocol.md §1 与根 README 实测表同步改数字。

## 硬约束与验收（同前两批规则，另加）
- P3 验收门：24pt 静止 σr 不劣化（基线 0.080pt）；20pt 中距/远距命中率劣化
  各 ≤ 5pp（基线 72%/44%）；detect_ms 降 ≥ 50%。不过门 = 不合入，写清数据后停。
- P4 验收门：Mac 端有效处理帧率 ≥ 25fps；localAim 到达间隔 p50 ≤ 40ms；
  连续 10 分钟 detect_ms 不漂移（无过热降频）。不达标回退 1/20 档。
- 每个 Phase 一个 git commit，message 写明验收结果

## 交付物
改动文件清单、P3 bench A/B 数据结论（合入或驳回的判定依据）、P4 实测数据、
docs/protocol.md / 根 README / docs/modules.md 同步、ADR-018 追加或新 ADR。
```
