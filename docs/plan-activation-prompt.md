# ScreenAim 定位优化方案 · kimi cli 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 分两次发更稳：第一次带「第一批：Phase 0 + Phase 1」，验收通过后再发第二次带「第二批：Phase 2 + Phase 3」。

---

## 提示词正文

```text
# 任务：执行 ScreenAim 定位优化方案

工作目录：/Users/jup33q/Documents/kimi/screen_aim
批次：第一批 = Phase 0 + Phase 1（第二批 = Phase 2 + Phase 3，等我确认后再做）

## 动手前必读（按顺序，全部读完再写代码）
1. docs/positioning-optimization-plan.md —— 本次任务书：§4 阶段划分、§7 文件级改动清单（含验收门槛）
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/architecture.md —— 线程模型与坐标系约定（新代码不得违反）
4. docs/protocol.md —— 线上格式；新增功能只加不删，保持向后兼容
5. docs/decisions.md —— 既有 ADR 格式；新增决策按 ADR-00X 追加

## 执行内容（本批次）
严格按方案 §7.1–§7.4 执行：
- Phase 0：检测耗时/分段延迟打点，CSV 表头扩展（timestamp,markers,ids,x,y,detect_ms,src）
- Phase 1.1：8 标记（4 角 + 4 边中点，id0–7）+ RANSAC/最小二乘单应
  （iPhone 纯 Swift 用 Accelerate 的 dsyev_ 做内点集精化，Mac 用 cv::findHomography RANSAC）
- Phase 1.2：MarkerDetector 亚像素角点精化（法向剖面 + TLS 直线拟合）
- Phase 1.3：ScreenAimCore 新增 OneEuroFilter.swift，双端输出侧接入

## 硬约束
- 不改 UI 布局与交互（ContentView.swift、Calibrator 视觉样式不动；仅按方案增加边中点标记位）
- 不改既有 TCP 协议字段语义；calib 下发 JSON 的 markers 字段与 screenCornerMap 同源自动扩为 8 项即可
- 注释全中文，新文件带 L0 文件头，实测数据注明条件；改行为同步改注释
- 像素数据不进主线程；SerialQueue 约定不变
- 每个 Phase 完成后必须跑：
    swift build && swift run ScreenAim --self-test
  iOS 侧改动后必须跑：
    cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
  （签名失败可接受，编译错误不可接受）
- 每 Phase 一个 git commit，message 写明验收结果

## 验收门槛（不过门槛不得进入下一 Phase）
- Phase 0：CSV 新列落盘正确，两端日志可读
- Phase 1.1：self-test 通过（自检场景需补 8 标记）；模拟遮挡任一角仍有输出
- Phase 1.2：24pt 标记静止 σ 不劣化；20pt 标记命中率从 ~0% 明显提升（数值写进验收小结）
- Phase 1.3：静止 σ 降 ≥50%

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. 每 Phase 的验收小结（实测值 vs 门槛，注明机型/分辨率/标记尺寸条件）
3. 新增 ADR-007（冗余标记 + RANSAC）；docs/protocol.md、docs/modules.md、docs/architecture.md 同步更新
4. 未决风险与第二批（Phase 2/3）的准备情况
```

---

## 第二批提示词（第一批验收通过后再发）

```text
# 任务：ScreenAim 定位优化方案 第二批（Phase 2 + Phase 3）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：Phase 0/1 已完成并验收。动手前重读 docs/positioning-optimization-plan.md §7.5–§7.8、
docs/comment-style.md、docs/protocol.md。

## 执行内容
- Phase 2.1：ScreenAimCore 新增 VisionMarkerDetector.swift（VNDetectBarcodesRequest，
  symbologies=[.dataMatrix]，payload "aim:N"，Vision 坐标左下原点须翻转）；
  ScreenLocalizer 加 detectorKind (.aruco/.vision/.both)，.both 为 A/B 模式双路落 CSV；
  Calibrator 用 CIFilter CIDataMatrixCodeGenerator 生成 DataMatrix 标记；
  --make-markers 加 --kind datamatrix。
- Phase 2.2：MarkerTracker.swift（VNSequenceRequestHandler + VNTrackObjectRequest，
  全量 8Hz + 跟踪补间，confidence<0.7 或 >150ms 触发重检）。
- Phase 3：UDP 结果通道（Bonjour TXT 加 udpport=9101；25B 大端包
  u32 seq|u64 sendMs|u8 markers|f32 x|f32 y|u8 flags；iPhone 50ms 定时器发送含心跳；
  Mac 新增 AimResultUDPListener，seq 计丢包，落 CSV src=udp）；protocol.md 新增 §9；
  TCP localAim 降为 1Hz 调试副本（保留兼容）。

## 硬约束与验收（同第一批规则，另加）
- 每个 Phase 后：swift build && swift run ScreenAim --self-test；
  iOS 改动后 xcodegen generate + xcodebuild 编译必须过。
- Phase 2 A/B 门槛：同场景双通道各录 5 分钟，Vision 集齐率 ≥ ArUco 且 σ 不劣化才切主通道，
  结论写 ADR-008（含切换或保留的判定依据与实测数字）。
- Phase 2.2：检测耗时均值降 ≥50%，输出间隔 p95 ≤ 35ms。
- Phase 3：推送间隔 p50 ∈ [48,52]ms、p95 < 65ms；丢包率 < 1%。
- 不做 Phase 4（路线切换评审）和 BLE/AWDL 兜底 PoC——出完数据停下来汇报。
- 文档同步：ADR-008/ADR-009、protocol.md §9、architecture.md 模块表、modules.md、
  README 实测表（注明条件）。

## 交付物
改动文件清单、每 Phase 验收小结（实测 vs 门槛）、A/B 对比数据结论、
是否建议进入 Phase 4（推翻 ADR-001 转手机端识别）的评估意见。
```
