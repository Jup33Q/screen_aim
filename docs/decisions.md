# 设计决策记录（ADR 精简版）

每条 = 决策 + 原因 + 推翻它之前要满足的条件。按时间倒序。

## ADR-020 恒定回报率原则：回报率只由被动背压决定，不由识别内容状态主动调制

- **决策**（2026-08-18，方案 constant-report-rate-plan.md CR0–CR2）：回退
  update-rate-optimization-plan §2 的 P1 无检出自适应降频（15Hz→3.3Hz，已随 822dc16
  入库，本批删除），`captureOutput` 恢复恒定 15Hz 识别门控（`localizeIntervalFull`
  保留，「识别不比发送更勤」论据保留——那是恒定速率高限不是主动降回报）。内容状态
  只影响"发什么"（有/无瞄准点、quality 等级），不影响"多久发一次"。配套落地 P2/CR2
  被动兜底：识别解耦到 `aimphone.localize` 串行队列 + NSLock busy 闸门
  （`localizeInFlight`，与 Mac 端 `frameInFlight` 同构），CPU 不足时丢旧保新——
  降帧数不降频率档位。替代保护三道：① busy 闸门（被动丢帧）；② JA1 发送时间戳 +
  Mac 端超龄丢弃（aim-jitter-analysis-plan）；③ CR3 检测器廉价早退（降单帧成本
  不降频率，bench 门控）。ADR-009 语义顺势扩展为「不抽稀、不降频」。
- **原因**：频率跳变本身就是白点抖动源——降频档 300ms 间隔恢复满速时，首批样本带
  300ms 级大 dt 注入 One Euro/速度低通，截止频率自适应误判，恢复瞬间白点抖动/过冲；
  白点重现延迟最坏 ~300ms 被降频档绑架；且降频触发条件（0 检出）与无输出条件
  （检出 <4）错位，语义裂缝。P1 的原始论据已消失：P0 Release 固化后 det 中位
  9–14ms@15Hz（2026-08-18 三段实测），省电力据无实测支撑属预防性优化。
- **推翻条件**：CR1/CR2 后真机 10 分钟会话实测 0 检出场景 CPU/功耗/温升仍不可接受，
  且 CR3 廉价早退（bench 门控）不达标——记录数据、升级讨论，也**不允许**退回
  内容状态主动降频（回退路径只到 revert 本批并标注「已暂停」+ 实测依据）。

## ADR-019 数码变焦双输入：二指手势 + 云台轮盘，轮盘目标从亮度改为变焦

- **决策**（2026-08-18，用户现场确认"手势和轮盘都能放大，只是两种形式"）：
  ① 相机预览加 `MagnificationGesture`：倍率 = 起手基线 × 手势比例，与轮盘共用
  `CameraStreamer.setZoomFactor`（唯一执行点，钳 [设备下限, min(3×, 设备上限)]——
  720p 输出宽 1280、12MP 传感器宽约 4032，≈3.1× 以内仍是欠采样裁切不丢有效分辨率；
  plan 原保守值 2×，真机反馈后放宽）；0.1× 刻度 + ±0.02/0.03 磁滞吸附 + 跨刻度
  `UIImpactFeedbackGenerator(.light)`（实测 selectionChanged 太弱、0.25× 刻度太疏），
  右上角 >1× 时常驻倍率指示（遵守隐形映射禁止）；② 云台轮盘 `onZoomDelta` 路由从亮度改为
  `adjustZoom(delta:)`（一格 ≈ ±5% 乘法增量，扳机门控不变，ADR-005），亮度调节
  完全留给太阳按钮滑杆（ADR-006）；③ 前后摄切换新设备回 1× 并同步 UI 状态；
  ④ 变焦是纯数码裁切，不改对焦距离，P0 对焦锁定（ADR-018）在变焦后照常有效，
  轮盘对焦微调（`nudgeFocus`）暂缓——轮盘目标已定为变焦，不再加切换态。
- **原因**：数码变焦直接放大标记像素，打"20pt 远距组帧上 8–15px"检出痛点；
  轮盘在云台手持场景比屏幕上双指更稳（手机夹云台上不便触屏），二指手势覆盖
  无云台/手持场景，两种形式同一执行点避免状态分叉。亮度自 ADR-003 手动曝光
  固定 1/120s 后只剩 ISO 一档粗调，太阳滑杆足够，轮盘让给更高频的变焦。
- **推翻条件**：实测 2× 下远距组命中率仍不达标（转 Vision/DataMatrix 通道或
  光学方案）；轮盘变焦与对焦微调都被证明高频刚需（届时加轮盘目标循环切换态，
  `requestRefocus()`/`nudgeFocus` 接口已预留）。

## ADR-018 对焦收敛后锁定 lensPosition，恶化自动解锁重 AF（对焦 P0）

- **决策**（2026-08-18，方案 focus-dial-plan.md §P0）：`CameraStreamer` 内联两态对焦
  状态机（focusing/locked，videoQueue 串行）。启动与前后摄切换（`flipCamera` 走
  `applyDeviceSettings` 天然重置）保持 `continuousAutoFocus`；本机识别连续 1s
  检出 ≥6/8 标记且锁定决策点 `isAdjustingFocus == false` 时
  `setFocusModeLocked(lensPosition:)` 锁当前位置；锁定中连续 10 次识别检出 <4 标记
  （满速 ≈0.7s，覆盖遮挡/移远移近）自动解锁重 AF，收敛后按同一判定重锁定。
  稳定信号选标记检出数为主、`isAdjustingFocus` 只瞬读不作持续 KVO 监听。
  `applyDeviceSettings` 增补 `focusPointOfInterest = (0.5, 0.5)`（先查
  `isFocusPointOfInterestSupported`）与 `autoFocusRangeRestriction = .near`。
  能力前置检查 `isFocusModeSupported(.locked)` +
  `isLockingFocusWithCustomLensPositionSupported`，任一不满足静默降级为纯 CAF
  （模拟器/部分前摄路径不变）。`requestRefocus()` 预留手动干预解锁入口
  （P1 轮盘微调 / P1.5 点按对焦用，本批次不接事件）。
- **原因**：失败链 = 屏幕内容时刻变化 → 对比度 AF 拉风箱 → 失焦帧 → 丢标记
  （README 20pt 中距失焦组命中率 72% 缺口的主要来源）；手机夹云台上、到屏距离
  物理固定（20–80cm），AF 收敛后锁定是安全的，检出数直接反映画面可用性，
  比单纯 isAdjustingFocus 更贴近"识别失败链终点"这一真实目标。
- **推翻条件**：真机实测锁定后检出率/命中率不升反降（调阈值或回退纯 CAF）；
  到屏距离固定前提不再成立（如手持模式）需重审锁定安全性；P2 refocus 协议
  落地后若解锁路径分叉过多，状态机独立成 FocusController。

## ADR-017 时敏消息独立 TCP 通道：同端口双连接 + hello 角色声明

- **决策**（2026-08-17）：执行 ADR-011 ④ 预留的推翻条款（单连接争用被实测证实）。
  iPhone 对同一 host:port 开第二条 TLV 连接（fast 通道），建立后先发
  `{"type":"hello","role":"fast"}` 声明角色，之后专发 localAim；视频/采集/鼠标/
  其余控制留主连接。Mac 端 `FrameServerV2` 吞掉 hello 并标记连接角色，
  `onControl` 带 isFast（CSV `src` 记 `tlv-fast` 供 A/B），`onConnect/onDisconnect`
  改连接计数门控（首连/全断才触发手机级状态翻转）。fast 未就绪时 iPhone 回退
  主连接发 localAim。配对路径（Bonjour/二维码/手动 IP）零改动。
- **原因**：localaim CSV 实测 ~22% 行到达间隔 <20ms（成批突发）——200B localAim
  排在 ~100KB JPEG 后的 TCP 队头阻塞（whitedot-latency-plan §0 #4，~10–30ms +
  抖动），且突发到达破坏 WP-L1 外推器的匀速到达假设。选**同端口双连接**而非
  独立端口：三条配对路径不必加端口字段、无版本错位；选 **TCP 而非 UDP**
  （WP-L3 维持暂缓）：丢包/乱序语义成本高，主要 HoL 项靠第二条 TCP 流即可消除。
- **推翻条件**：双通道后 CSV 成批比例仍未显著下降（说明瓶颈不在传输排队，
  转查 WP-L2 提频或滤波段）；或双连接在目标网络下引入新争用（退回单连接，
  fast 通道代码保留但不启用）。

## ADR-016 启用 TLV type 2 Codable 信封：白点 × UI 重叠 → iPhone 震动反馈

- **决策**（2026-08-17）：推翻 P3「type 2 不启用」结论（protocol.md §11）。
  `ScreenAimCore.AimMessage`（Codable enum，JSONEncoder 默认 enum 编码）作为
  type 2 信封双端同源；首条消息 `aimUIHover(overlapping:)`（Mac → iPhone）：
  `Calibrator.updateDotUIOverlap` 在 `placeAimDot`（三处摆点路径唯一漏斗）末尾
  实时求交白点与**顶部控制面板 NSPanel + 8 个定位码白卡**（frame 不缓存，
  滑杆 rebuild 后面板/白卡几何自动跟随），边沿翻转即 `FrameServerV2.send`
  广播；白点隐藏路径（断连 / 滑行耗尽）经 `resetDotUIOverlap` 复位边沿状态。
  iPhone 端 `TLVTransport` 接收循环路由 type 2 → `CameraStreamer.handleMessage`，
  进入重叠（`overlapping == true`）时 `UIImpactFeedbackGenerator(.light)` 震一次，
  离开不震。存量 type 1 控制消息不迁移。
- **原因**：用户明确要求结构化消息用 Codable enum（类型安全、双端同源），
  且震动信号是瞬态边沿事件——与 type 1 的 JSON 字典消息相比，enum case 的
  编译期完整性检查对「新增信号双端同步」更省事；只加不迁保持向后兼容
  （旧 iPhone 接收循环只认 type 1，type 2 自动忽略）。
- **推翻条件**：type 2 消息增长到需要版本协商或二进制体积敏感时——先在
  `AimMessage` 内加 case 解决；真要换编码（如二进制），新占一个 type 号，
  不要改动 type 2 既有线上格式。

## ADR-015 Mac 显示段 60Hz 匀速死推算外推摆点（WP-L1）

- **决策**（2026-08-17，方案 docs/whitedot-latency-plan.md §1）：`Calibrator` 起
  60Hz 主 runloop 定时器，两次 localAim 到达（≈15Hz，ADR-009）之间用
  `AimCoastFilter` 新增的只读接口 `displayExtrapolation(at:)` 把白点重摆到
  `lastOut + coastVel × Δt` 外推点（Δt 封顶 120ms `maxDisplayExtrapolation`，
  封顶后原地保持；未初始化/已 reset 返回 nil；y 翻转 + 屏内钳制与到达帧、
  滑行帧共用 `placeAimDot`，禁止第二份换算）。不改滤波状态、不计入断流滑行
  预算（滑行仍只由 `update(raw: nil)` 帧计数控制），到达帧 `update()` 输出
  仍是权威位置；白点隐藏（滑行耗尽/断连）时定时器空转直接返回。
  **窗口内不做速度衰减**——这是对方案 §1 原文"衰减沿用 coastHalfLife"的有意
  偏离：0.1s 半衰期会把 +66ms 推进量压低 ~24%，匀速 300pt/s 时偏离真值 ~7pt
  并在每个上报间隔制造 ~15Hz 锯齿，与 <1pt 外推精度验收直接冲突；过冲防护由
  120ms 封顶 + 新样本到达即校正承担（方案 §5 风险登记本就以这两条为主力）。
- **原因**：白点"到达才摆"在 15Hz 上报下产生 ≤66ms 保持滞后 + 阶梯感
  （方案 §0 #6），是滞后预算里纯显示侧、零识别风险的最大可压缩项；运动中
  感知滞后估算从 ~100–150ms 降到 ~50–80ms。
- **推翻条件**：实测网络延迟突增时外推过冲可感知——先把
  `maxDisplayExtrapolation` 调小；若确需衰减，给显示段引独立的长半衰期，
  不要复用 coastHalfLife（0.1s 在 ≤120ms 窗口内衰减过猛）。

## ADR-014 白点滤波三层增强 + 双端分层解耦（WP3）

- **决策**（2026-08-17，方案 §3）：主滤波器不更换（One Euro 就是为人手指针场景
  发明的，方案 §3.1 对比表），在 `AimCoastFilter` 一个实现内叠三层增强：
  ① **跳变门限**（WP3.1）：新样本与预测距离 > k × max(近期残差 σ̂ EWMA, 2.0pt 下限)
  时本帧保持预测输出（= 一帧滑行），单帧跳变恰好拦 1 帧——拦截/滑行后首帧旁路
  门限（残差里是真实位移不是噪声），旁路帧照常更新 σ̂ 使持续快速运动时门限
  自适应放宽；k 默认 2.5、可关（0/nil）；
  ② **断帧滑行**（WP3.2）：同 ADR-013 的 AimCoastFilter 机制，双端共用；
  ③ **双端分层解耦**（WP3.3）：iPhone 识别段强消抖（`AimFilterPreset.phone`，
  对 15Hz 原始识别噪声，用相机 PTS 做时间轴），Mac 显示段只做 15Hz→显示的
  插值平滑 + 跳变门 + 滑行（`AimFilterPreset.macDisplay`，截止频率明显更高，
  不重复消抖）。口语化预设三档（稳如三脚架/日常跟手/疾速响应）+ 四个单项旋钮，
  人话映射表见 docs/aim-filter-tuning.md；Mac 端 CLI `--filter-preset` /
  `--dot-*`，预设经 calib `filterPreset` 字段下发 iPhone（协议只加不删）。
- **原因**：现状两端各一段同参数 1€ 串联，双段都消抖导致横扫滞后叠加；
  RANSAC 漏网的 5–20pt 级单帧跳变会把白点甩出去（无门限实测甩 14.3pt）；
  瞬时掉检（中位 2 帧）白点直接消失。滤波必须留在 iPhone 段用相机 PTS 做
  时间轴——网络到达抖动会污染 dt（§11 Nagle 攒批实测即证据），全挪到 Mac
  端滤波消抖质量必然下降，且滤波是纯 CPU 计算、不上行任何额外数据。
- **推翻条件**：跳变门误压真实快速移动被实测证实（调 k 或关闭，预设已分档兜底）；
  出现比 One Euro 更适配人手指针场景的滤波算法族并有本场景实测数据支持。

## ADR-013 3 点仿射兜底 + 断帧滑行（边角几何饥饿的软件修复，WP1）

- **决策**（2026-08-17，方案 docs/edge-localization-and-filter-plan.md §1）：
  ① iPhone 纯 Swift 定位层（`ScreenLocalizer.solveAim`）匹配恰好 3 对时退化为仿射变换
  （`AffineTransform`，三点 Cramer 闭式解，无需 Accelerate），输出等级
  `quality=affine`；**发散护栏**：映射瞄点超出三点外接框以框心放大 1.5 倍的范围时
  仍返回 nil（`affineGuardFactor`，护栏外宁可无输出）；
  ② 检出不足/护栏拒绝时不断帧即丢：`AimCoastFilter`（ScreenAimCore 新文件，双端共用）
  按 One Euro 最近低通速度外推、速度按 ≈100ms 半衰期指数衰减，最多 5 帧
  （≈330ms@15Hz），输出 `quality=coast`，超 5 帧才返回 nil；
  ③ localAim 上报与 localaim CSV 新增 `quality` 字段/列（homography/affine/coast），
  协议只加不删，旧端忽略。
- **原因**：2026-08-17 四真机会话（约 2 万帧）统计：无瞄准帧的 10–25% 是
  「检出 1–3 个标记」的几何饥饿（近距瞄角视野只有角标 + 相邻边中点的 L 形簇，
  不够 RANSAC ≥4 对门槛），连续无瞄准段中位仅 2 帧。屏幕是平面，三点簇内仿射
  与单应误差 pt 级，掉检空窗用速度衰减滑行填充即可转化绝大部分缺失帧。
  **设计推导**：WP1.2 方案原文"沿用上一有效变换外推"与速度衰减滑行等价——
  帧中心在帧像素系恒为 (w/2, h/2)，旧变换重投影每帧输出同一点，正是速度为零的
  滑行特例；故 WP1.2 与 WP3.2 收敛为 `AimCoastFilter` 一个实现，禁止两处各写一份。
- **推翻条件**：护栏外假阳性被实测证实（先收紧 `affineGuardFactor` 或加凸包内判定）；
  滑行输出被证实误导用户（调 `maxCoastFrames` 至 0 即回退旧行为）；
  WP2 卫星标记 A/B 达标使三点簇帧消失（仿射兜底自然不再触发，代码保留）。

## ADR-012 Wi-Fi Aware 通道终止：macOS SDK 层不可用（P0 尖刺结论）

- **决策**（2026-08-17 P0 尖刺）：ADR-011 之③（WA 升首选通道）**终止**。
  传输主路径降级为 **TLV + Bonjour**（`_aimphone2._tcp` 过渡期 + 9100 单端口收敛），
  扫码/手工 IP 永久兜底不变；WA 归档"待生态成熟"。TLV 部分（ADR-011 ①②④）不受影响。
- **原因**（三条独立证据，复现脚本 `tools/wa-spike/`）：
  ① Xcode 26.6 SDK 中 `WiFiAware.framework` 全部公开符号（`WACapabilities` /
  `WAPublishableService` / `WASubscribableService` 等 29 处）标注
  `@available(macOS, unavailable)`（iOS 26.0+ 可用，macCatalyst 亦不可用）——
  Mac 端代码**编译期**即无法引用，包壳 .app 也救不了；
  ② macOS 26 Network.framework 接口只有 `NWError.wifiAware` 错误码，没有
  `.wifiAware` 端点描述符与 `NWParameters.wifiAware` 选项——Mac 做不了 WA listener/publisher；
  ③ 运行系统（macOS 26.6.1）上 `/System/Library/Frameworks/WiFiAware.framework`
  是无二进制的空壳（仅 Resources + 签名）。
  注：skills/wifi-aware-pairing 所引"macOS 26.0 支持"（论坛 827887）与 SDK 事实矛盾，以 SDK 为准。
- **推翻条件**：未来 Xcode/macOS SDK 将 WiFiAware 开放给 macOS 原生进程
  （重跑 `tools/wa-spike/run.sh` 编译通过即信号），届时按 transport-26-plan §3 原设计恢复。

## ADR-011 全 26+ 部署前提下传输层四项复审决策

> 执行状态（2026-08-17）：①②④已实施完毕（P1 过渡期双服务并行一个版本周期→
> P3 拆除旧链路并收敛 9100 单端口，真机回归全绿）；③被 ADR-012 推翻（WA 终止）。
> Coder type 2 评估结论（P3）：不启用，继续预留（理由见 protocol.md §11）。

- **决策**（2026-08-17 传输方案复审，详见 docs/transport-26-plan.md §4）：
  ① V2（TLV）真机回归通过后**拆除 9100 手工分帧服务与 iPhone 旧传输实现**——项目
  "只加不删"兼容文化（protocol.md §6/§7）的首次例外，过渡期双服务并行一个版本周期；
  ② iPhone 部署目标升 26.0，删除全部 `if #available` 双栈（DockKit 下限 17 仍满足）；
  ③ Wi-Fi Aware 由"第三通道"升为**首选通道**，Bonjour 降备用，扫码/手工 IP 永久兜底；
  ④ 采集回传并入主 TLV 连接（type 10/11），撤销独立端口；端口收敛为 9100 单端口。
- **原因**：新部署前提（目标机全部 iOS 26/macOS 26+）抽掉了原两方案保守设计的地基
  （现场无 <26 客户端）；用户明确要求传输内容最大化移交 Network.framework / Wi-Fi Aware。
  WA 首选可同时兑现无路由器直连、免本地网络授权弹窗、datapath 强制加密三项收益。
- **推翻条件**：现场出现无法升级 26 的设备（恢复旧链路，git 历史可完整回滚）；
  P0 尖刺证明 Mac 包壳 .app 无法发布 WA 服务（WA 降级，TLV+Bonjour 主路径照常）；
  采集回传与视频流单连接争用被实测证实（退回独立端口，TLV 栈不变）。

## ADR-010 默认标记尺寸 24pt → 48pt

- **决策**：`Calibrator` 默认 `markerSize` 与 iPhone 内置默认映射表同步改为 48pt
  （`--marker-size 24` 可调回，顶部面板滑杆也可实时调）。
- **原因**：24pt 是 1280 宽降采样**本机采屏**的实测可靠下限，但手机远距离实拍
  （屏幕占画面比例小）边中点标记掉检严重，真机验证 48pt 检出 >6/8。
  代价是屏幕占位变大，由滑杆/参数兜底。
- **推翻条件**：远距离识别鲁棒性提升（Vision/DataMatrix 通道切主，见
  docs/positioning-optimization-plan.md）后重新评估默认值。

## ADR-009 localAim 上报从抽稀改为每帧全量（≈15Hz）

- **决策**：iPhone 本机识别结果不再 1/5 抽稀（原 ≈2–4Hz），每帧识别每帧上报。
- **原因**：Mac 端白点覆盖层与 debug 对照的流畅度依赖上报频率，2Hz 下白点跳动
  明显；控制帧体积小（<200B），相对 15fps JPEG 视频流带宽占比可忽略。
  光标跟随（--aim-cursor）走 Mac 侧视频帧识别，不依赖本上报。
- **推翻条件**：控制信道与视频帧同一 TCP 连接，若上报被证实挤占视频带宽
  （延迟/卡顿回归），改回抽稀或白点改由 Mac 侧识别直接驱动。

## ADR-008 鼠标键按下状态 Mac 侧跟踪 + 断连双路兜底补发 up

- **决策**：Mac 端 `Calibrator` 维护 `pressedMouseButtons` 集合；iPhone 主动断开前
  补发 `mouseUp button:"all"` 兜底帧；Mac 连接被动断开（`FrameServer.onDisconnect`）
  再对残余按键补发 up（对未按下的键收到 up 是安全 no-op）。
- **原因**：按住中时断连（杀 App/断网/关机）真实鼠标键会卡死在按下态，表现为
  整屏拖拽/选中失控且用户难归因；网络层不保证兜底帧必达，故收发两端各补一道。
- **推翻条件**：改用系统级 HID 设备方案（驱动断开自动释放按键），或协议层引入
  心跳租约自动失效机制。

## ADR-007 冗余 8 标记 + RANSAC/最小二乘单应

- **决策**：屏幕四角 + 四边中点共 8 个定位码（id0–7，Calibrator 自动布局），
  检出与映射表匹配 ≥4 对即求解单应。Mac 端 `cv::findHomography(RANSAC, 3.0)`；
  iPhone 纯 Swift 端 `Homography(ransacSrc:dst:)`（随机抽 4 点 DLT + 内点集
  Accelerate dsyev_ 最小二乘精化）。
- **原因**：旧方案要求 4 角恰好集齐，缺一即整帧无输出，单帧掉检/手指遮挡是常态；
  冗余标记把"帧级命中率"变成"系统级可用率"，对本场景收益大于换字典
  （docs/positioning-optimization-plan.md §1.2）。
- **推翻条件**：8 标记对屏幕 UI 遮挡被确认不可接受，或 Vision/DataMatrix 通道
  切主后标记布局整体重设计。

## ADR-006 太阳按钮用单一 DragGesture 状态机，不用 Tap/LongPress 组合

- **决策**：落指起计时 0.35s，按住即激活亮度条，竖拖调节，短按收起；全部在一个
  DragGesture 里完成。
- **原因**：SwiftUI 的 TapGesture 与 LongPressGesture 叠加存在手势竞争，
  拖动中误触长按、松手时机不可靠。单一手势 + 显式状态（pressActive /
  pressActivated / pressMoved）行为完全确定。
- **推翻条件**：SwiftUI 手势系统修复竞争问题，或交互模型本身改版。

## ADR-005 DockKit 按键全部"扳机门控"

- **决策**：轮盘/快门/翻转键只在扳机（`.button`）按住时生效；轮盘值转增量，
  基线始终更新防止跳变。
- **原因**：不门控时，直接转轮盘云台机械臂会跟随运动，与 App 功能打架；
  按住扳机恰好是云台自身的机械锁定动作，语义天然吻合"功能修饰键"。
- **推翻条件**：目标云台固件改变扳机语义，或找到不依赖扳机的无冲突映射。

## ADR-004 主动关闭 DockKit 人物追踪

- **决策**：docked 即 `setSystemTrackingEnabled(false)`，退出/退后台/undock 显式恢复。
- **原因**：本 App 瞄准的是屏幕不是人，系统追踪会让云台跟着人转，破坏瞄准。
  该设置不持久，但按 DockKit 规范仍显式恢复。
- **推翻条件**：产品形态变为需要追踪。

## ADR-003 相机手动曝光 1/120s + 低 ISO

- **决策**：`applyDeviceSettings` 锁定 1/120s，ISO 取 minISO×1.5 起步；
  "亮度调节"实际调的是 ISO（minISO → minISO×10），快门不变。
- **原因**：拍屏幕必须压住刷新条纹；屏幕本身发白，自动曝光会过曝。
  README 早期写 1/60s，实现已改 1/120s，条纹抑制更好。
- **推翻条件**：换高刷新/无 PWM 屏幕目标场景，或改用硬件 ND。

## ADR-002 预览旋转交给 RotationCoordinator，不手动监听设备方向

- **决策**：`AVCaptureDevice.RotationCoordinator`（iOS 17+）+ KVO，
  且有三个缺一不可的同步时机（角度变化 / session startRunning /
  didMoveToWindow）。
- **原因**：冷启动手机固定在云台上时没有方向变化事件，UIDevice 方向在启动
  瞬间不可靠，手动映射会导致横屏画面翻转。RotationCoordinator 以窗口场景
  为准且自带正确初始值。
- **推翻条件**：最低系统版本降到 iOS 17 以下（需回退方案并重测冷启动横屏）。

## ADR-001 Mac 端识别（路线 B），手机端零识别逻辑

- **决策**：手机只采集 + JPEG 推流，ArUco 检测与 homography 全部在 Mac。
- **原因**：手机端零第三方依赖（纯 AVFoundation + Network），算力/发热友好；
  Mac 端 OpenCV 生态成熟，迭代快。
- **代价**：依赖局域网，延迟约 100ms。
- **推翻条件**：需要脱机/无 Mac 使用，或延迟敏感场景。
