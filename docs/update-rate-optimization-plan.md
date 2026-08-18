# 更新速率优化方案（手机端识别提速 · P0–P4）

> 状态：**待实施**。激活提示词见 [update-rate-activation-prompt.md](update-rate-activation-prompt.md)。
> 前置阅读：[architecture.md](architecture.md)（线程模型）、[protocol.md](protocol.md) §7/§11、
> [comment-style.md](comment-style.md)、[decisions.md](decisions.md) ADR-009/015/017、
> [aim-filter-tuning.md](aim-filter-tuning.md)。
> 约束：不改 TLV 线上消息格式；localAim 字段只加不删；不改 UI 布局与交互；
> 像素数据不进主线程；Mac 端 busy 闸门 / fast 时敏通道 / 60Hz 外推等既有正确基础不动。

## 0. 问题与根因（2026-08-18 实测诊断）

### 0.1 实测数据（scenes/localaim_*.csv）

| 会话（本机时间） | localAim 更新速率 | 手机端 detect_ms 中位 | 通道 | 手机构建 |
|---|---|---|---|---|
| 08-17 17:55（3.7h，n=117856） | 8.8 Hz | 15 ms | tlv | Release（release-artifacts IPA，08-16 打包） |
| 08-17 21:38（n=13727） | 7.2 Hz | 8 ms | tlv | 同上 |
| **08-18 09:59（进行中）** | **1.5 Hz** | **640 ms**（p90 669，max 773） | tlv-fast | Debug（Xcode 直接部署，测未提交 prefilter 改动） |

当前会话另有一个独立症状：中后段 **0 标记检出**（手机未对准屏幕或标定层未显示），
白点处于断流状态。0 检出帧同样每帧烧 640ms 全帧扫描——无标记场景是耗时最坏情况
（噪点组件成百上千，prefilter + decode 封顶 32 候选在 Debug 下依然昂贵；
MarkerDetector.swift 注释内已有同类实测记录：256 上限时无标记场景 553ms/帧）。

### 0.2 根因清单

| # | 现象 | 根因 | 位置 |
|---|---|---|---|
| ① | localAim 从 8–15Hz 掉到 1.5Hz | 手机端纯 Swift 检测器跑在 **Debug 构建**（-Onone），全帧管线（灰度→自适应阈值 23px 窗→two-pass union-find→prefilter→decode）在 1280×720 上慢 ~80 倍（8–15ms → 640ms） | ios 构建配置；`Sources/ScreenAimCore/MarkerDetector.swift` |
| ② | 识别一慢，视频帧与 localAim 一起被压到同速率 | **识别 / JPEG 编码 / 发送同挤 `aimphone.capture` 串行队列**：`captureOutput` 里 `localizeFrame`（同步 640ms）→ JPEG 编码 → `send` 顺序执行，识别阻塞期间发送完全停摆；识别门限 10ms ≈ 相机每帧都识别，远超发送所需的 15Hz | `ios/AimPhone/CameraStreamer.swift` `captureOutput` |
| ③ | 0 检出场景持续满速烧 CPU | 无标记时识别无降频/早退，Debug 下 640ms×持续 = 队列永久饱和，连恢复检出的机会都被稀释 | 同上 |

已具备、**不要动**的正确基础：`noDelay(true)`（Nagle 攒批实测修复）、
fast 时敏通道双连接（ADR-017，localAim 已避开视频 JPEG 队头阻塞）、
Mac 端 busy 闸门丢旧保新（main.swift `frameInFlight`）、60Hz 显示外推（ADR-015）、
CapturePipeline 有界背压（tlv-blocking-optimization-plan P0）、看门狗与断开兜底（ADR-008）。
**网络层经核实不是瓶颈**：15fps×~100KB ≈ 1.5MB/s，局域网远未打满。

### 0.3 速率天花板说明（即使 CPU 瓶颈解决后）

- 发送闸门 `frameInterval = 1/15`：白点/光标更新天花板上限 15Hz（P4 可选提升）；
- Mac 端识别 ~30ms/帧（1280 宽降采样，29fps 能力），不是瓶颈；
- 端到端延迟构成：采集间隔 66ms + 识别 15ms(Release) + JPEG ~15ms + 网络 ~10–30ms
  + Mac 识别 30ms ≈ 130–150ms（Release 构建下的健康基线）。

## 1. P0：真机构建固化 Release（非代码改动，收益最大）

**目标**：消灭"Debug 构建上真机"这一类事故。640ms → 8–15ms，更新率立刻回 8–15Hz。

### 改动点（二选一，以验证命令的结果为准）

1. **首选（durable）**：`ios/project.yml` 用 XcodeGen 自定义 scheme，把 Run 配置的
   Build Configuration 固定为 Release（`xcodegen generate` 后不丢失）；
2. **兜底（一次性）**：Xcode → Product → Scheme → Edit Scheme → Run → Build Configuration
   = Release（重新 xcodegen 会丢，仅应急）。

### 验收

- `cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj -scheme AimPhone
  -showBuildSettings | grep SWIFT_OPTIMIZATION_LEVEL`：Run 配置对应 `-O`（非 `-Onone`）
- 真机部署后跑 §6 会话验收：detect_ms 中位 ≤ 20ms，localAim 速率 ≥ 8Hz
- `docs/development.md` 补一条排错项：「真机 detect_ms 突然涨几十倍 → 检查是否
  Debug 构建上机」；根 README「手机端」小节注明日常真机验证用 Release 构建

## 2. P1：无标记自适应降频（小改动，防卡死 + 省电）

**目标**：连续 0 检出时识别自动退到低频档，不再满速烧 CPU 挤占推流；
检出恢复立即回满速。Debug 构建误上线时也不会把推流压死。

### 改动点（`ios/AimPhone/CameraStreamer.swift`）

1. 识别间隔从固定 10ms 改为两档（常量集中文件头部，注释写清依据）：
   - 满速档：`localizeIntervalFull = 1.0 / 15.0`（对齐发送闸门 15Hz——识别比发送
     更勤没有意义，原来 10ms 门 ≈ 相机每帧都识别是浪费）
   - 降频档：`localizeIntervalIdle = 0.3`（300ms，3.3Hz 保活扫描，足以在
     标记回到视野后 300ms 内恢复）
2. 档位切换：连续 0 检出（`localize` 结果 `markers.isEmpty`）满 **10 次**进降频档；
   任一帧检出 >0 立即回满速档。
3. 安全性论证（写进 NOTE 注释）：进降频档的门槛（10 次）> 断帧滑行预算
   （maxCoastFrames 5 帧，ADR-013），即降频只在滑行早已耗尽、无输出后触发，
   不改变白点滑行语义；`registerNoAim` 的 10 帧滤波器 reset 路径不受影响。
4. 只降识别频率：**不影响** JPEG 发送闸门、不影响未连接分支的扫码
   （`checkPairingQR` 逻辑不动）、不影响 `captureRecorder` 录制（录制由
   localizeFrame 尾部驱动，降频档录制抽帧率随之下降——采集会话期间建议
   人工保持标记在视野内，写进 NOTE）。

### 验收

- `swift build && swift run ScreenAim --self-test` 全过（ScreenAimCore 未动，回归确认）
- iOS 编译过（`cd ios && xcodegen generate && xcodebuild ... build`）
- 真机：镜头捂黑/移开屏幕 5 秒后，LOCALAIM 日志间隔降到 ~300ms；
  移回屏幕 1 秒内恢复满速识别；白点行为（含边角 3 标记仿射兜底）与改动前一致

## 3. P2：识别挪出采集串行队列（解耦，busy 闸门丢旧保新）

**目标**：识别耗时不再阻塞 JPEG 编码与发送——发送稳定打满 15fps 闸门，
识别慢时只降低本机识别/上报频率，不再拖垮整条推流链路。

### 改动点（`ios/AimPhone/CameraStreamer.swift`）

1. 新增 `localizeQueue = DispatchQueue(label: "aimphone.localize")`；
   `localizeFrame` 从 videoQueue 同步调用改为 localizeQueue 异步执行。
2. busy 闸门（与 Mac 端 main.swift `frameInFlight` 同构，NOTE 注明对应关系）：
   NSLock + `localizeInFlight` 标志；处理中时新到的识别请求**直接丢弃**
   （识别结果可丢，下一帧会覆盖），禁止排队积压。
3. `CVPixelBuffer` 跨队列生命周期：入队前 `CVPixelBufferRetain`，
   localizeFrame 返回后 `CVPixelBufferRelease`（函数内部 baseAddress
   lock/unlock 已有，不动）；WARNING 注释：漏 release 会耗尽帧池卡死采集。
4. `captureRecorder.record` 调用随迁（它在 localizeFrame 尾部、依赖 pb 持锁）；
   NOTE：录制期 PNG 编码 30–60ms/帧会占用 localizeQueue 拖慢识别——与现状
   （拖慢 videoQueue 推流）相比只是换了受害者，可接受；record 再拆独立队列
   超出本 plan 范围。
5. JPEG 编码 + `send` + `framesSent` 计数留在 videoQueue 不动；
   扫码分支（未连接时）留在 videoQueue 不动。
6. 顺序性说明（NOTE）：busy 闸门保证任一时刻至多一帧在识别，localAim 上报
   顺序天然保持，无乱序风险。

### 验收

- `swift build && swift run ScreenAim --self-test`；iOS 编译过
- 真机 Release 构建：推流有效帧率（Mac 端 FPS 日志）稳定 ≥ 14fps，
  localAim 到达间隔 p50 ≤ 130ms
- **Debug 构建反向验证**（故意 Debug 部署一次）：localAim 速率下降但
  视频推流帧率应基本不受影响（解耦生效的直接证据），验证完切回 Release
- 内存平坦（仪器或 Xcode gauges 观察 3 分钟，无帧池泄漏）

## 4. P3：检测输入降采样（bench 门控，不达标不合入）

**目标**：全帧管线在 640×360 上跑（像素数 ÷4），detect_ms 目标降 ≥50%。

### 改动点（`Sources/ScreenAimCore/MarkerDetector.swift`）

1. 新增 `inputScale = 1`（1=原分辨率，2=半分辨率；灰度转换阶段隔像素采样实现，
   不动 CVPixelBuffer 读取路径）；检出的角点/中心坐标 ×scale 映射回原坐标系。
2. 参数联动在 detector 内集中处理：`minSide`、`minCellGap`、亚像素精化的
   法向剖面半径等像素单位参数按 scale 折算（WARNING：漏折算任一参数 =
   小标记检出率静默劣化）。
3. 亚像素角点精化（Phase 1.2）可选保留在全分辨率灰度上执行（实现换精度），
   由实施者按 bench 结果决定，结论写进验收小结。
4. iOS 端 `ScreenLocalizer` 默认开 scale=2 与否**由 bench 门决定**，默认先不动。

### 验收门（不过门不合入真机默认）

- `tools/make_bench_scenes.py` 生成基准场景 + `--replay` A/B（scale 1 vs 2）：
  - 24pt 静止 σr 不劣化（基线 0.080pt）
  - 20pt 中距失焦组命中率劣化 ≤ 5pp（基线 72%）；20pt 远距组劣化 ≤ 5pp（基线 44%）
  - detect_ms 降 ≥ 50%
- 真机复测用 §6 会话验收：检出率与静止 σ 不劣化

## 5. P4：发送闸门 15 → 30fps（可选，P0–P2 验收后评估）

**目标**：白点/光标更新天花板从 15Hz 提到 30Hz。带宽 ~3MB/s，局域网无压力；
Mac 端 60Hz 外推（ADR-015）与 busy 闸门已兼容更高到达率。

### 改动点

- `ios/AimPhone/CameraStreamer.swift` `frameInterval` 1/15 → 1/30（一行）；
  同步更新 protocol.md §1「15fps」表述与根 README 协议描述（只改数字与实测表，
  不改格式）。

### 验收门

- 真机 Release：Mac 端有效处理帧率 ≥ 25fps（识别 30ms/帧能跟上）；
  localAim 到达间隔 p50 ≤ 40ms；连续 10 分钟无过热降频（detect_ms 不漂移）
- 不达标回退 1/20 中间档，结论与实测写进验收小结

## 6. 统一会话验收方法（各 Phase 真机验收共用）

```bash
# 1. Mac 端跑会话 ≥3 分钟（含静止 + 横扫 + 贴边角各一段）
swift run ScreenAim --calibrate --serve 9100
# 2. 会话结束后分析最新 CSV（速率 / detect_ms / 检出率）
python3 tools/plot_localaim.py   # 或按 README 指示分析 scenes/localaim_最新.csv
```

关键指标：更新速率 = 1/到达间隔中位（tlv-fast 行）；detect_ms 中位/p90；
有瞄准点占比。实测数据注明机型/系统/标记尺寸/构建配置（文档维护约定 ④）。

## 7. 实施顺序与影响面

| 顺序 | 阶段 | 影响文件 | 文档同步 |
|---|---|---|---|
| 1 | P0 Release 固化 | `ios/project.yml`（或 Xcode scheme） | development.md 排错项、根 README |
| 2 | P1 无检出降频 | `ios/AimPhone/CameraStreamer.swift` | modules.md CameraStreamer 条目 |
| 3 | P2 识别解耦 | `ios/AimPhone/CameraStreamer.swift` | architecture.md 线程模型、modules.md、ADR-018 |
| 4 | P3 降采样（bench 门控） | `Sources/ScreenAimCore/MarkerDetector.swift` | modules.md、bench 数据进验收小结 |
| 5 | P4 30fps（可选） | `ios/AimPhone/CameraStreamer.swift` | protocol.md §1、根 README 实测表 |

- 每阶段独立验收、独立 commit（message 写明实测 vs 门槛）、单文件级可回退
- P0/P1/P2 彼此无依赖可分开上；P3 依赖 bench 工具链；P4 必须在 P0–P2 之后评估
- 决策记录：P1+P2 合并记 **ADR-018**（手机端识别调度：Release 固化 + 队列解耦 +
  无检出降频），写明 2026-08-18 实测数据依据；P3/P4 若达标各记一条或在 ADR-018 追加
- 真机回归基线（每阶段后）：配对/标定下发/白点/鼠标三键+滚轮/断开兜底/采集回传
