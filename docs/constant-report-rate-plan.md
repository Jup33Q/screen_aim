# 恒定回报率方案（去主动降频 · CR0–CR3）

> 状态：**CR0–CR2 已实施**（2026-08-18，同批 commit；真机验收按 §6 表执行中）。
> P1 降频代码实际已随 822dc16 入库（非原文假设的"工作区未提交"），CR1 按正常编辑删除；
> 新增 ADR 按 decisions.md 实际最大号顺延为 **ADR-020**（原文的 ADR-019 编号引用过期），
> 不修订任何既有 ADR。
> 前置阅读：[update-rate-optimization-plan.md](update-rate-optimization-plan.md)（P0–P4，
> 尤其 §2 P1 的原始论据）、[aim-jitter-analysis-plan.md](aim-jitter-analysis-plan.md)
> （JA1 时间阀是配套机制）、[decisions.md](decisions.md) ADR-009/013/015/017、
> [aim-filter-tuning.md](aim-filter-tuning.md)、[comment-style.md](comment-style.md)。
> 约束：不改 TLV 线上消息格式；localAim 字段只加不删；不动 AimCoastFilter 三层机制
> （One Euro / 跳变门 / 断流滑行）；不动发送闸门与 Mac 端 60Hz 显示外推。

## 0. 动机：为什么要避开主动降回报率

### 0.1 对象界定

「主动降回报率」= 根据**识别内容状态**（检出与否）主动调制识别/上报频率的做法，
当前唯一实例是 update-rate-optimization-plan §2 的 **P1 无检出自适应降频**：

- 连续 0 检出（`markers.isEmpty`）满 10 次 → 识别间隔 66ms → 300ms（15Hz → 3.3Hz）；
- 任一帧检出 >0 → 立即回满速。
- 代码现状（2026-08-18）：已实现于 `ios/AimPhone/CameraStreamer.swift`
  （`localizeIntervalIdle` / `localizeIdleThreshold` / `consecutiveNoMarkerFrames` /
  `currentLocalizeInterval`），**未 commit**，工作区 diff +38 行。

满速档对齐发送闸门的 15Hz 上限**不属于**主动降回报——那是「识别不比发送更勤」的
恒定速率高限，本 plan 不动；P4（15→30Hz）的评估也不受影响。

### 0.2 P1 当初的论据与现状核对

| P1 原始论据（§2 / §0.2 ③） | 2026-08-18 现状 | 结论 |
|---|---|---|
| 0 检出场景满速识别烧 CPU（Debug 实测 640ms/帧，队列永久饱和） | P0 已固化 Run scheme = Release 并验收（det 中位 9–14ms @15Hz ≈ 单核 15–20% 占用）；Debug 误上线由 scheme 固化 + development.md 排错项兜底 | 论据基本消失 |
| 识别慢会挤占 videoQueue 压垮推流 | P2（识别挪独立队列 + busy 闸门丢旧保新）未实施，但它是**被动**背压：CPU 不够时自然丢帧，不需要主动降档 | 由 P2 替代（CR2 硬依赖） |
| 省电 | 无实测数据支撑；Release 下 15Hz 识别增量功耗未知，需先测再谈优化（CR3 提供降单帧成本而非降频率的选项） | 不成立的预防性优化 |

### 0.3 主动降频的实际代价（本 plan 的核心论点）

1. **频率跳变本身就是抖动源**（与白点抖动问题直接相关）：降频档 300ms 间隔期间
   iPhone 端 aimFilter 被"饿死"，恢复满速的首批样本带着 300ms 级大 dt 注入
   One Euro 与速度低通——dt 失真 → 截止频率自适应误判 → 恢复瞬间白点轨迹抖动/
   过冲。恒定 15Hz 下 dt 序列平稳，滤波器工作在设计点上。
2. **恢复延迟最坏 ~300ms**：标记回到视野到下一次识别的间隔被降频档绑架；
   叠加识别 + 链路 + Mac 显示段，白点重现比恒定 15Hz 多拖 ~200ms。
   手持场景"扫出屏幕再扫回来"是高频动作，这个延迟可感知。
3. **语义裂缝**：降频触发条件是 `markers.isEmpty`（0 检出），但无输出的条件是
   检出 <4（ADR-007 仿射兜底前 <3）。局部遮挡剩 1–3 个标记时**不降频也无输出**，
   而 0 检出（镜头完全移开）才降频——降频档保护的场景恰恰是最不需要
   快速响应的场景，设计目标与实际行为错位。
4. **采集副作用**：录制抽帧由 localizeFrame 尾部驱动，降频档采集帧率同步掉到
   3.3Hz（P1 自己的 NOTE 已承认，"建议人工保持标记在视野内"是给用户添负担）。
5. **与 JA1 时间阀叠加后语义模糊**：JA1 落地后 Mac 端按 ts 做超龄丢弃，
   对端主动拉稀的报文流会让"链路攒批"与"对端降频"在数据里不可区分，
   污染 jitter_report 的攒批率指标。

### 0.4 设计原则（写进 ADR）

> **回报率只由被动背压决定（发送闸门 / busy 闸门 / 链路流控），不由识别内容状态
> 主动调制。** 内容状态只影响"发什么"（有/无瞄准点、quality 等级），不影响
> "多久发一次"。资源不足时用被动机制降负载：busy 闸门丢旧保新（降帧数不降档位）、
> 检测器廉价早退（降单帧成本不降频率）。

## 1. CR0：前置核实（无代码改动）

1. 确认 P1 的 38 行 diff 未 commit（`git status` / `git diff ios/AimPhone/CameraStreamer.swift`）；
2. 确认 P0 验收数据仍成立（update-rate-optimization-plan §1 的三段实测：
   det 中位 ≤ 20ms、localAim 30Hz、Release）；
3. 确认 P2 未实施（无 `localizeQueue` / `localizeInFlight`）——决定 CR1/CR2 顺序。

## 2. CR1：移除 P1 主动降频（iOS 单文件）

**前置**：CR0 通过。若 P2 已先行实施则直接合入；否则本步只做"工作区 revert 级"
清理，与 CR2 同 commit 或紧随 CR2 之后合入（理由：去掉降频后，Debug 误上线的
队列饱和事故只剩 busy 闸门一道兜底，两道保护不应同时缺席）。

### 改动点（`ios/AimPhone/CameraStreamer.swift`）

1. 删除 `localizeIntervalIdle` / `localizeIdleThreshold` /
   `consecutiveNoMarkerFrames` / `currentLocalizeInterval` 四个成员及
   「识别调度（无检出自适应降频）」MARK 块；
2. `captureOutput` 的识别门控恢复为恒定间隔：
   `now0 - lastLocalizeTime >= localizeIntervalFull`（15Hz，对齐发送闸门的
   原论据保留：识别比发送更勤没有意义）；
3. `localizeFrame` 尾部删除降频档位切换计数（0 检出计数块）；
4. 原 MARK 块位置留一节 NOTE，写清设计决策与替代保护，防止后人重新引入：
   - 决策：不做内容状态主动降频（本 plan §0.4 原则，ADR 编号见 §5）；
   - CPU 保护 = P0 Release 固化 + P2 busy 闸门（被动丢帧）；
   - 过时消息保护 = JA1 发送时间戳 + Mac 端超龄丢弃；
   - 单帧成本优化走 CR3 廉价早退（不降频率）。
5. 注释遵循 comment-style.md；ADR-009「每帧全量上报不抽稀」的语义顺势扩展为
   「不抽稀、不降频」，在注释中交叉引用。

### 验收

- `swift build && swift run ScreenAim --self-test` 全过（ScreenAimCore 未动，回归确认）
- iOS 编译过（`cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj
  -scheme AimPhone build`）
- `git diff` 确认除上述删除与 NOTE 外无行为性改动

## 3. CR2：被动保护补齐——识别解耦 + busy 闸门（即原 P2，前置依赖升级）

原 update-rate-optimization-plan §3 P2 的内容**原样采用**，此处只变更其地位：
从「可选优化」升级为去降频的**硬依赖兜底**——它是 CPU 不足时唯一合法的降载机制
（被动丢旧帧，不降频率档位）。

### 改动点摘要（以 update-rate-optimization-plan §3 为准）

1. `localizeQueue` 独立串行队列 + NSLock busy 闸门（`localizeInFlight`，
   与 Mac 端 `frameInFlight` 同构，NOTE 注明对应关系）；
2. CVPixelBuffer 跨队列 retain/release（WARNING：漏 release 耗尽帧池卡死采集）；
3. JPEG 编码 + send + 扫码分支留 videoQueue 不动；captureRecorder 调用随迁；
4. 顺序性 NOTE：busy 闸门保证任一时刻至多一帧在识别，localAim 上报顺序天然保持。

### 验收

- 沿用 §3 验收门，其中「Debug 构建反向验证」一条在本方案下意义升级：
  故意 Debug 部署，捂黑镜头（0 检出最坏场景）持续 30 秒——**视频推流帧率应
  基本不受影响，localAim 速率被动下降但不压死推流**（被动背压生效的直接证据，
  替代 P1 的事故保护角色），验证完切回 Release

## 4. CR3：检测器廉价早退（可选，bench 门控，不降频率降成本）

若实测（CR1/CR2 后真机 10 分钟会话）表明 0 检出场景的 CPU/功耗/温升仍是问题，
优化方向是**降单帧成本**而非降频率：

1. 灰度转换后先做全帧低方差/全黑快检（均方差 < 阈值 ≈ 无内容），命中则跳过
   阈值化 + union-find + decode，返回空结果，耗时 < 1ms——频率不变，成本蒸发；
2. 阈值与命中率的 trade-off 必须过 bench 门（`--replay` A/B：命中率零劣化才合入），
   严防把低对比度真实标记误判为"无内容"；
3. 不达标则放弃本项，结论写进验收小结；**禁止**退回"降频率"方向。

## 5. 文档同步与决策记录

| 文件 | 改动 |
|---|---|
| `docs/update-rate-optimization-plan.md` | §2 P1 标注「已回退，见 constant-report-rate-plan」（状态行同步更新）；§3 P2 标注「升级为 CR2 硬依赖」 |
| `docs/modules.md` | CameraStreamer 条目：删降频描述，改「恒定 15Hz 识别（不主动降频，ADR-020）」 |
| `docs/decisions.md` | 新增 **ADR-020 恒定回报率原则**：回报率只由被动背压决定；P1 回退的实测依据（P0 三段数据）与替代保护（busy 闸门 / JA1 时间阀 / CR3 早退）。既有 ADR 一律不修订 |
| `docs/aim-jitter-analysis-plan.md` | §0 缺口②行末交叉引用本 plan（时间阀与恒定回报是同一问题的两面：一个管"旧的不进"，一个管"新的不停"） |
| `docs/development.md` | 排错项补充：「识别率异常掉档 → 检查是否有人重新引入了内容状态降频（违反 ADR-020）」 |

## 6. 统一验收门（CR1+CR2 合入后一次真机验收）

沿用 update-rate-optimization-plan §6 方法（Release、三段会话 ≥3 分钟/段、
注明机型/系统/标记尺寸/构建配置），在本方案特有项上加测：

| 指标 | 门槛 | 对应论点 |
|---|---|---|
| 捂黑 5s 后移回屏幕：白点重现延迟 | ≤ 250ms（vs 降频档最坏 ~500ms） | §0.3-2 |
| 恢复瞬间（标记重新进入视野后 1s 窗）跳变数 | ≤ 1 帧（jitter_report，同 JA2 门） | §0.3-1：恒定 dt 不污染滤波器 |
| 捂黑 30s（Release）：CPU/温升 | 无过热降频，detect_ms 不漂移 | §0.2 省电力据核对 |
| 0 检出段 localAim 到达间隔 | p50 ≈ 66ms 恒定（不再有 300ms 档） | 行为直接证据 |
| 遮挡剩 1–3 标记段 vs 0 检出段的上报节奏 | 一致（语义裂缝消除） | §0.3-3 |
| 回归：配对/标定下发/白点/鼠标三键+滚轮/断开兜底/采集回传 | 全部通过 | 每阶段惯例 |

## 7. 风险与回退

| 风险 | 兜底 |
|---|---|
| Debug 误上线且 busy 闸门失效 | P0 scheme 固化是主防线；development.md 排错项；真机日常只用 Release |
| Release 下 0 检出长时 CPU 占用超预期 | CR3 廉价早退（bench 门控）；仍不达标则记录数据、升级讨论，不回退到主动降频 |
| JA1 未落地期间旧消息重放抖动 | 与本方案正交，JA1 激活提示词独立于本 plan，可并行 |

回退路径：CR1/CR2 单 commit 级可 revert；ADR-019 保留但标注「已暂停」并写明
触发回退的实测数据。

## 8. 激活提示词

```
激活 docs/constant-report-rate-plan.md。先完整读该 plan、
docs/update-rate-optimization-plan.md（§2 P1 / §3 P2）、docs/decisions.md
（ADR-009/013/018 草稿）、docs/comment-style.md，再读
ios/AimPhone/CameraStreamer.swift 的识别调度 MARK 块、captureOutput、localizeFrame。

按 plan 实施 CR0 → CR2 → CR1 的顺序核对依赖：
1. CR0：确认 P1 的 38 行 diff 未 commit、P2 未实施，汇报核实结果；
2. CR2 先行：实施识别解耦 + busy 闸门（原 P2 内容，改动点以
   update-rate-optimization-plan §3 为准）；
3. CR1：移除 P1 主动降频四成员与档位逻辑，恢复恒定 15Hz 识别门控，
   原 MARK 块留 ADR-019 决策 NOTE（不主动降频 + 三道替代保护的指针）；
4. 文档同步按 plan §5 表逐项落地（ADR-019 新增、ADR-018 草稿修订、
   update-rate-optimization-plan P1 标回退、modules.md/development.md 更新）。

硬约束：不改 TLV 线上格式与既有字段语义；AimCoastFilter 三层机制不动；
禁止用"降频率"解决任何新暴露的成本问题（走 CR3 bench 门控的早退方向）。
改完跑 swift build && swift run ScreenAim --self-test，再 cd ios &&
xcodegen generate && xcodebuild -project AimPhone.xcodeproj -scheme AimPhone build；
真机验收按 plan §6 表执行（含 Debug 捂黑反向验证一次），实测数据写进 commit message。
CR3 不在本次范围内，等真机 CPU/温升数据说话。
```
