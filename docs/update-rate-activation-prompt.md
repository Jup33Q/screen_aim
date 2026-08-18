# 更新速率优化方案 · 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 当前进度：**发「第一批（续跑）」**（P0 三段验收收尾 + P1），通过后发
> 「第二批：P2」，再发「第三批：P3 → P4」（P3 是 bench 门控，不过门不合入；P4 可选）。
> 方案本体：[update-rate-optimization-plan.md](update-rate-optimization-plan.md)。

---

## 第一批（续跑）提示词（P0 三段验收收尾 + P1 无标记自适应降频）

> 2026-08-18 进度：收尾提交 c3c442c（ADR-017/prefilter）与插入批 a794810
> （扫码修复 + 配对按钮合并）已入库；P0 代码与文档已落地但未提交（待三段验收）。
> 旧版第一批提示词已被实际执行覆盖，以下续跑提示词为准。

```text
# 任务：ScreenAim 总路线图 B1 续跑（P0 验收收尾 → P1 无检出降频）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
当前状态（2026-08-18，均已 git log 核实）：
- c3c442c 收尾提交：ADR-017 fast 通道 + ADR-016 type 2 信封 + prefilter 预筛
  + CapturePipeline 背压 + WP-I1 IMU 代码（真机冒烟通过）
- a794810 插入批：扫码途中连上 scanning 复位 + 配对按钮合并（真机三项验证通过）
- P0 未提交 3 文件：ios/project.yml（scheme Run=Release）、docs/development.md
  （排错项 3 条）、README.md（手机端 Release 注记）——故意挂起等验收数据
- P0 即兴实测（Release，iPhone 15 Pro Max / iOS 26 / 48pt 标记，213s 混合会话）：
  detect_ms 中位 9.8 / p90 10.6 / max 15.7；到达间隔中位 33ms（30.3Hz）；
  有瞄准点 88%（homography 1233 / affine 637 / coast 207）——已超门槛，
  但用户要求正式验收按三段分别录制

## 动手前必读（按顺序，全部读完再写代码）
1. docs/master-plan.md —— §0.2 未提交清单、§3 全局硬约束
2. docs/update-rate-optimization-plan.md —— §2 P1 改动清单、§6 验收方法
3. docs/comment-style.md —— 注释五级体系规范
4. docs/architecture.md 线程模型；docs/decisions.md ADR-009/013/017

## 执行内容（顺序不可换）
1. P0 三段验收：真机 Release 构建已部署则直接用；静止 / 横扫 / 贴边角
   （L 形 3 标记簇）各录 ≥1 分钟，**每段重启 Mac 服务产生独立 CSV**
   （swift run ScreenAim --calibrate --serve 9100）。逐段分析
   scenes/localaim_*.csv：detect_ms 中位 ≤ 20ms、localAim ≥ 8Hz 过门槛后，
   git commit P0 三文件（message 写三段实测 vs 门槛）
2. P1 无检出降频（ios/AimPhone/CameraStreamer.swift，按 plan §2）：
   识别间隔两档（满速 localizeIntervalFull = 1/15s / 降频 localizeIntervalIdle
   = 0.3s，常量集中文件头部）；连续 0 检出满 10 次进降频档，检出即回满速；
   安全性论证 NOTE（门槛 10 > 滑行预算 5，ADR-013）；扫码/JPEG 发送/
   captureRecorder 不动。真机验收：镜头移开 5s 后 LOCALAIM 间隔 ~300ms，
   移回 1s 内恢复满速，白点（含边角仿射兜底）行为不变。commit（message 写实测）
3. docs/modules.md CameraStreamer 条目补两档说明

## 环境坑（2026-08-18 实测，勿再踩）
- xcodebuild/devicectl 前加 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  （xcode-select 指向 CLT）
- 真机构建 -derivedDataPath 用 /tmp（~/Documents 是 iCloud 同步目录，fpfs xattr
  会让 codesign 报 detritus not allowed）
- 部署：devicectl device install app / process launch / process terminate --pid
  （terminate 前用 device info processes 取当前 pid，旧 pid 可能是僵尸项）
- Mac 服务端重启即产生新 localaim CSV（分段录制靠这个）

## 硬约束
- 不改 TLV 线上格式；localAim 字段只加不删；不改 UI；像素数据不进主线程
- 每步完成后：swift build && swift run ScreenAim --self-test；
  iOS 改动后 cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj
  -scheme AimPhone -destination 'generic/platform=iOS' build
- 每步一个 git commit，message 写明实测 vs 门槛
- 联调测试项逐条标注【新功能】/【旧功能】（用户偏好，iphone-linked-dev skill 已收录）

## 交付物
1. P0/P1 验收小结（三段 CSV 各自实测 vs 门槛，注明机型/系统/标记尺寸/构建配置）
2. docs/modules.md 同步；docs/master-plan.md §0 U1 状态推进
3. 未决风险（已知：按住键杀进程 Mac 补发 up 的断开检测延迟待查，用户指示鼠标
   链路优先级后置；ios/AimPhone 2.xcodeproj 与 Info 2.plist 垃圾文件待确认清理）
   与 B2（P2 识别解耦 + tlv-blocking P2 发送侧闸门）的准备情况
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
