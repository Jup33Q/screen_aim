# ScreenAim 总路线图 · 激活提示词

> 用法：进入项目目录后，按批次把对应「提示词正文」整段发给 kimi cli，**一批一验**，
> 验收通过再发下一批。批次顺序与优先级定义见 [master-plan.md](master-plan.md)。
> 本文件是总入口；子 plan 自带提示词仍有效，但批次划分以本文件为准。
> 2026-08-18 重排：**防抖簇 D1–D3 提到最高优先**，B1 已完成；原 B2 的识别解耦
> 被 D1 吸收，B2 缩编为 B2′（只剩 tlv-blocking P2）。

---

## 批次 D1（防抖·恒定回报率：CR0 核实 → CR2 识别解耦+busy 闸门 → CR1 移除降频）

> 详版任务书：[constant-report-rate-plan.md](constant-report-rate-plan.md)
>（动机 §0 / 改动点 §2–§3 / 验收门 §6）。D2 用 [aim-jitter-analysis-plan.md](aim-jitter-analysis-plan.md)
> §5 的 JA1 提示词，D3 用同文件 JA2 提示词，均不在此复制。

```text
# 任务：ScreenAim 总路线图 D1（白点防抖·恒定回报率 CR0→CR2→CR1）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
背景：无检出主动降频（15Hz→3.3Hz）本身是白点抖动源——恢复满速时 300ms 级大 dt 注入
One Euro/速度低通，滤波器误判截止频率，恢复瞬间白点抖动/过冲。本批移除它并补上
被动保护（busy 闸门）。防抖簇为当前最高优先级（master-plan 2026-08-18 重排）。

## 动手前必读（按顺序，全部读完再写代码）
1. docs/constant-report-rate-plan.md —— 本批任务书（动机/改动点/验收门 §6/风险 §7）
2. docs/update-rate-optimization-plan.md §2/§3（P1 原始论据 / P2 改动清单）
3. docs/decisions.md —— ADR-009/013/014/015/017/018/019（注意 018=对焦锁定、
   019=变焦双输入，均已在库且本批不得改动其行为）
4. docs/comment-style.md —— 注释五级体系规范
5. 现状代码：ios/AimPhone/CameraStreamer.swift（"识别调度" MARK 块、captureOutput、
   localizeFrame；对焦状态机 focusFeed 与变焦 applyZoom 已存在，不要动）
6. 对照实现：Sources/ScreenAim/main.swift 的 frameInFlight busy 闸门段（同构参考）

## 与 plan 原文的前提偏差（按事实执行，不要按原文假设）
- CR plan 假设"P1 降频代码未 commit、工作区 +38 行 diff"——实际已入库（c3c442c）。
  CR1 = 删除已合入代码，走正常编辑而非工作区 revert
- CR plan 文中的"ADR-019"编号引用全部过期：本批新增「恒定回报率原则」ADR 以
  decisions.md 实际最大号顺延（预计 ADR-020）；不修订任何既有 ADR

## 执行内容（依赖顺序：CR0 → CR2 → CR1）
1. CR0 核实：确认降频代码已入库（c3c442c）、P2 未实施（无 localizeQueue/
   localizeInFlight）、P0 Release 固化验收数据仍成立；先汇报核实结果再动手
2. CR2 先行：localizeQueue 独立串行队列 + NSLock busy 闸门（localizeInFlight，
   与 Mac 端 frameInFlight 同构，NOTE 注明对应关系）；CVPixelBuffer 跨队列
   retain/release（WARNING：漏 release 耗尽帧池卡死采集）；captureRecorder 调用
   随迁；对焦状态机 focusFeed 调用随 localizeFrame 一起迁；JPEG 编码/发送/扫码
   分支留 videoQueue 不动；顺序性 NOTE（busy 闸门保证至多一帧在识别，localAim
   上报顺序天然保持）
3. CR1：删除 localizeIntervalIdle / localizeIdleThreshold / consecutiveNoMarkerFrames /
   currentLocalizeInterval 四成员与降频档位逻辑，captureOutput 恢复恒定 15Hz 识别
   门控（localizeIntervalFull 保留，"识别不比发送更勤"论据保留）；原 MARK 块位置
   留 NOTE：不主动降频决策（新 ADR）+ 三道替代保护（busy 闸门 / JA1 时间阀 /
   CR3 早退）指针
4. 文档同步：decisions.md 新增恒定回报率 ADR；update-rate-optimization-plan §2 P1
   标「已回退，见 constant-report-rate-plan」、§3 P2 标「已由 CR2 实施」；
   modules.md CameraStreamer 条目删降频描述；development.md 加排错项
   （识别率异常掉档 → 检查是否有人重新引入内容状态降频）

## 硬约束
- 不改 TLV 线上格式与既有字段语义；AimCoastFilter 三层机制不动；
  对焦锁定（ADR-018）与变焦（ADR-019）行为不动
- 禁止用"降频率"解决任何新暴露的成本问题（走 CR3 bench 门控的早退方向）
- 注释全中文并遵循 comment-style.md；像素数据不进主线程；串行队列约定不破坏
- 完成后必须跑：
    swift build && swift run ScreenAim --self-test
    cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
- CR3 不在本次范围内，等真机 CPU/温升数据说话

## 验收（真机，按 constant-report-rate-plan §6 表逐项，注明机型/系统/构建配置）
- 捂黑 5s 后移回屏幕：白点重现 ≤ 250ms；恢复后 1s 窗内跳变 ≤ 1 帧（jitter_report）
- 捂黑 30s（Release）：无过热降频，detect_ms 不漂移
- 0 检出段 localAim 到达间隔 p50 ≈ 66ms 恒定（不再有 300ms 档）
- 遮挡剩 1–3 标记段与 0 检出段上报节奏一致
- Debug 构建捂黑反向验证一次：视频推流基本不受影响，localAim 被动降速但不压死
  推流（busy 闸门生效的直接证据），验证完切回 Release
- 回归：配对/标定下发/白点/鼠标三键+滚轮/断开兜底/采集回传 + 对焦锁定与变焦冒烟
- 一个 git commit（CR2+CR1 可同 commit），message 写明实测 vs 门槛

## 交付物
1. CR0 核实结论  2. 改动文件清单（逐个说明）  3. §6 验收表逐项实测数据
4. 新 ADR（编号顺延，预计 ADR-020）+ 文档同步清单  5. D2（JA1 时间戳）衔接说明
```

---

## 批次 D2 / D3（防抖·数据基础 / 防抖·实验）

D1 验收通过后：D2 直接发 [aim-jitter-analysis-plan.md](aim-jitter-analysis-plan.md)
§5 的 **JA1 激活提示词**（localAim 加 ts/pts + Mac 超龄丢弃）；
D2 入库后 D3 发同文件的 **JA2 激活提示词**（三档预设 A/B，用户跑动作脚本）。

---

## 批次 B1（速率·速效）——已完成 ✅

> P0 Release 固化 commit a99d940（三段真机验收过）；P1 无检出降频已入库（c3c442c）
> 但经 constant-report-rate-plan 复审判定回退——由 D1 的 CR1 执行删除。
> 原续跑提示词存档于 git 历史。

---

## 批次 B2′（速率·弱网：tlv-blocking P2 发送侧丢帧闸门）

> 原 B2 的 update-rate P2（识别解耦 + busy 闸门）已被 D1 的 CR2 吸收实施，
> 本批只剩发送侧闸门，故缩编为 B2′。前置：D1 已验收。

```text
# 任务：ScreenAim 总路线图 B2′（速率优化·弱网批）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：D1 已完成并验收（识别解耦 + busy 闸门已在库，恒定 15Hz 识别）。
本批只剩 tlv-blocking P2：iOS 发送侧 videoInFlight 闸门。

## 动手前必读
1. docs/tlv-blocking-optimization-plan.md §3（发送侧 videoInFlight 闸门改动清单）
2. docs/comment-style.md、docs/architecture.md 线程模型
3. docs/decisions.md 最新恒定回报率 ADR（识别侧闸门已就位，本批与其同构）
4. 现状代码：ios/AimPhone/TLVTransport.swift、ios/AimPhone/CameraStreamer.swift
   （send(jpeg:) 路径与识别解耦后的队列结构）

## 执行内容
- send(jpeg:) 改 videoInFlight 闸门 + 可丢帧异步发送；videoDropped 计数接进
  CameraStreamer 现有状态日志；注释写清"视频可丢、控制/采集不动"
- 顺序性说明：单连接视频发送任一时刻至多一条在途，TLV framer 保消息原子性

## 硬约束与验收（继承 master-plan §3，另加）
- 真机 Release：视频有效帧率 ≥ 14fps，localAim 到达间隔 p50 ≤ 130ms
- 弱网实测（Network Link Conditioner 3G/Edge 档）：编码回调周期不漂移、
  videoDropped 随档位上升而 framesSent 不淤积、网络恢复 1s 内回满帧率；
  强网回归 videoDropped ≈ 0
- 内存观察 3 分钟平坦（无帧池泄漏）
- 一个 commit，message 写明实测 vs 门槛

## 交付物
改动文件清单、验收小结（含弱网数据）、docs/modules.md 同步、
tlv-blocking-optimization-plan.md 状态头更新（P2 完成）、新 ADR（编号顺延）。
```

---

## 批次 B3（速率·提频：update-rate P3 降采样 bench → P4 30fps，吸收 WP-L2）

```text
# 任务：ScreenAim 总路线图 B3（速率优化·提频批）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：防抖簇 D1–D2 与 B2′ 已完成并验收。本批吸收 whitedot-latency-plan WP-L2
（15→30Hz 提频评估），WP-L2 不再单独执行；WP-L3（UDP）维持暂缓。

## 动手前必读
1. docs/update-rate-optimization-plan.md §4/§5（改动清单与验收门）
2. docs/whitedot-latency-plan.md §2（WP-L2 的评估维度，并入 P4 验收）
3. docs/positioning-optimization-plan.md Phase 1 的 bench 方法
   （tools/make_bench_scenes.py + --replay A/B）
4. docs/comment-style.md

## 执行内容
- P3：MarkerDetector.swift 加 inputScale（1/2，灰度阶段隔像素采样），坐标 ×scale
  映射回原系；minSide/minCellGap/亚像素剖面半径等像素参数集中按 scale 折算
  （WARNING 注释）；亚像素精化是否保留全分辨率由 bench 结果决定。
  先 --replay A/B 拿数据——不过门不合入真机默认，写清数据后停下来汇报。
- P4（P3 有结论后，且经我确认）：frameInterval 1/15 → 1/30；
  protocol.md §1 与根 README 实测表同步改数字（只改数字与实测表，不改格式）。

## 硬约束与验收（继承 master-plan §3，另加）
- P3 门：24pt 静止 σr 不劣化（基线 0.080pt）；20pt 中距/远距命中率劣化各 ≤ 5pp
  （基线 72%/44%）；detect_ms 降 ≥ 50%
- P4 门：Mac 端有效处理帧率 ≥ 25fps；localAim 到达间隔 p50 ≤ 40ms；
  白点输出间隔 p95 ≤ 35ms（WP-L2 门并入）；连续 10 分钟 detect_ms 不漂移
  （无过热降频）。不达标回退 1/20 档，结论写验收小结
- 每个 Phase 一个 commit，message 写明实测 vs 门槛

## 交付物
改动文件清单、P3 bench A/B 数据结论（合入或驳回的判定依据）、P4 实测数据、
docs/protocol.md / 根 README / docs/modules.md / whitedot-latency-plan.md 状态头
（WP-L2 已并入验收）同步、新 ADR（编号以 decisions.md 实际最大号顺延）。
```

---

## 批次 B7（交互·对焦：focus-dial P1.5 点按对焦 + 对焦框 UI）

> P0 对焦锁定（ADR-018）与变焦双输入（ADR-019）已入库。本批让位于防抖簇，
> 防抖+速率收口后启动。提示词用 [focus-dial-activation-prompt.md](focus-dial-activation-prompt.md)
> 的「下一批提示词（P1.5）」，不再在此复制。

---

## 批次 B8（交互·扳机短按 = 鼠标左键单击）

```text
# 任务：ScreenAim 总路线图 B8（交互·扳机短按 = 鼠标左键单击）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
背景：已确认 Flow 2 Pro 扳机走 DockKit .button(id:pressed:) 通道，按下/松开边沿
可被捕获（GimbalManager 现有 pressedButtons/triggerHeld 机制与上屏日志即证据）。
将扳机短按魔改为鼠标左键单击；按住仍是修饰键（ADR-005 扳机门控不变）。

## 动手前必读（按顺序）
1. docs/decisions.md —— ADR-005（扳机门控）、ADR-008（断连兜底补发 mouseUp）
2. docs/comment-style.md —— 注释五级体系规范
3. skills/dockkit-button-mapping/SKILL.md —— .button 通道语义（唯一能做按住语义的
   通道）与 DON'T 清单
4. 现状代码：ios/AimPhone/GimbalManager.swift（listenAccessoryEvents 的 .button
   case、pressedButtons/triggerHeld 边沿）、ios/AimPhone/ContentView.swift
   （gimbal.* 闭包注入点；streamer.sendMouseDown/Up 已存在）

## 执行内容
1. GimbalManager：.button 按下沿（held false→true）记录 triggerPressTime；
   松开沿时长 <0.3s → 触发新增闭包 onTriggerClick；≥0.3s 属修饰键语义不触发。
   注释写清取舍：不区分短按/按住的话，按住+轮盘变焦会在 Mac 上造成左键长按拖选
2. ContentView 注入：onTriggerClick → streamer.sendMouseDown("left") +
   sendMouseUp("left")（既有协议消息，ADR-008 断连补 up 兜底天然覆盖）
3. 云台 pill 图例与 GimbalManager 类头文档同步（扳机 = 短按单击 / 按住修饰）
4. id 核实前置：先读 debug 面板「按键 id=N 按下/松开」日志确认扳机的 id；
   若实测发现扳机之外还有按键走 .button 通道，按 id 细分只响应扳机

## 硬约束与验收
- 不改协议；注释全中文遵循 comment-style.md；模拟器静默降级
- 真机：短按扳机 → Mac 光标处产生单击；按住 0.3s 以上松开 → 无单击；
  按住+轮盘变焦正常且不产生单击/拖选；断连不卡键
- 一个 git commit，message 写明验收结果；新增 ADR（扳机短按=单击一条，
  编号按 decisions.md 顺延，与 ADR-005 交叉引用）；docs/modules.md 同步

## 交付物
1. 改动文件清单  2. 真机验收小结（含扳机 id 实测记录，顺手回填
   dockkit-button-mapping/references/flow2pro.md 实测矩阵的扳机行）
3. 新 ADR + 文档同步清单
```

---

## 批次 B4（IMU 融合：WP-I1 续跑 → WP-I2 → WP-I3 评估）

```text
# 任务：ScreenAim 总路线图 B4（IMU 融合）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：防抖簇 D1–D3 与速率簇 B2′/B3 已收口（或按 master-plan §1 与速率批穿插）。
WP-I1 代码已完成验证，录制中断于手机散热——先续跑，不要重写代码。

## 动手前必读
1. docs/imu-fusion-plan.md —— §1 WP-I1 四问定义、§2 WP-I2、§3 WP-I3、§4 总验收
2. docs/imu-wp-i1-resume-prompt.md —— 续跑现场状态（代码就绪清单与断点）
3. docs/comment-style.md、docs/decisions.md ADR-013/014/015

## 执行内容
1. WP-I1 续跑：按 resume-prompt 的现场状态补录（注意散热：分段录制、
   段间冷却，手机摘壳/避免边充边录），完成四问分析
2. WP-I2（WP-I1 数据支持才做）：Mac 显示段 IMU 驱动外推，替换/增强 WP-L1 的
   匀速死推算；静止 σ 与跳变门行为不得劣化
3. WP-I3：评估先行，数据不达标不上——只出评估报告，不实施

## 硬约束与验收
- IMU 只做增量传播/外推，ArUco 视觉检出永远是唯一绝对锚点
- 继承 master-plan §3 全局硬约束；验收按 imu-fusion-plan §4 逐项过
- 每 WP 一个 commit；WP-I2 落地记 ADR（编号以 decisions.md 实际最大号顺延）

## 交付物
WP-I1 四问数据结论、WP-I2 验收小结（实测 vs 门槛）、WP-I3 评估报告、
imu-fusion-plan.md 状态头更新、相关 ADR 与文档同步。
```

---

## 批次 B5（识别质量扩展：Vision DataMatrix A/B + MarkerTracker）

```text
# 任务：ScreenAim 总路线图 B5（识别质量扩展，门控式）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：防抖簇与速率簇收口（D1–D3、B2′/B3）。动手前重读 docs/positioning-optimization-plan.md
§7.5–7.6、docs/comment-style.md、docs/protocol.md。
注意：plan-activation-prompt.md 旧文「ADR 顺延为 012/013」已作废——
ADR-012/013 已被占用，新 ADR 一律以 decisions.md 实际最大号顺延。

## 执行内容
- Phase 2.1：VisionMarkerDetector（VNDetectBarcodesRequest DataMatrix，
  payload "aim:N"，Vision 坐标左下原点须翻转）+ detectorKind A/B 双路落 CSV +
  Calibrator CIDataMatrixCodeGenerator 生成标记 + --make-markers --kind datamatrix
- Phase 2.2（2.1 A/B 达标才做）：MarkerTracker（VNSequenceRequestHandler 跟踪补间，
  全量 8Hz + confidence<0.7 或 >150ms 重检）

## 硬约束与验收（继承 master-plan §3，另加）
- Phase 2.1 A/B 门：同场景双通道各录 5 分钟，Vision 集齐率 ≥ ArUco 且 σ 不劣化
  才切主通道；结论写 ADR（含切换或保留的判定依据与实测数字）
- Phase 2.2 门：检测耗时均值降 ≥ 50%，输出间隔 p95 ≤ 35ms
- UDP（Phase 3）不在本批范围，出完数据停下来汇报

## 交付物
改动文件清单、A/B 对比数据结论、验收小结、ADR 与 protocol.md/modules.md 同步、
是否建议评审 UDP 通道的评估意见。
```

---

## 批次 B6（交互体验：Liquid Glass 光标）

```text
# 任务：ScreenAim 总路线图 B6（白点 × Liquid Glass 光标交互）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：防抖簇 D1–D3 收口（白点数据流稳定是磁吸手感的前提）。
动手前完整读 docs/liquid-cursor-plan.md（§1 可行性分层、§2 实施计划、§3 风险）、
docs/comment-style.md。

## 执行内容
严格按 liquid-cursor-plan §2 的 WP 划分逐段实施：磁吸状态机（free → attracting →
snapped，滞回进 16pt/出 24pt 以 plan 为准）→ 形态 morph → 液滴融合；
自有 UI 目标优先于外部 App 目标的排队规则按 plan §2 接入。

## 硬约束与验收
- 本批是唯一允许动 UI 视觉的批次，但仍不改交互逻辑与白点数据流语义
- 继承 master-plan §3；每 WP 一个 commit；视觉走查 + 白点跟踪回归（无拖拽感劣化）
- ADR 记磁吸状态机 / container 选型 / btnPanel 不迁移的理由（编号顺延）

## 交付物
改动文件清单、逐 WP 走查记录、ADR 与文档同步。
```
