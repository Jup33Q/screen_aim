# ScreenAim 总实施路线图（Master Plan）

> 日期：2026-08-18（当日二次重排）· 定位：各子 plan 的**调度层**——只排优先级与批次，
> 改动细节、验收门一律以被引用的子 plan 为准，本文不复制。
> 优先级（用户 2026-08-18 二次指定）：**白点防抖 > 网络与识别速率优化 > IMU 融合 >
> 识别质量扩展 > 交互体验**。
> （覆盖首次排序「速率 > IMU > 识别质量 > 交互」。防抖簇与速率簇的交集——
> update-rate P2 识别解耦——被防抖批次 D1（constant-report-rate-plan CR2）吸收，
> 速率簇不再重复排期；速率簇仍以不劣化识别质量为验收门。）
> 激活提示词：[master-activation-prompt.md](master-activation-prompt.md)。

## 0. 项目进度盘点（2026-08-18，以 commit / ADR / 实测为准）

### 已完成 ✅

| 事项 | 出处 |
|---|---|
| 定位 Phase 0/1.1–1.3：8 标记冗余 + RANSAC、亚像素精化、One Euro 滤波 | ADR-007，positioning-optimization-plan |
| 边角定位修复 WP1/WP3：3 点仿射兜底 + 断帧滑行 + 滤波三层增强 + 调参面板 | ADR-013/014，edge-localization-and-filter-plan |
| 白点滞后 WP-L1：Mac 显示段 60Hz 匀速死推算外推 | ADR-015，whitedot-latency-plan |
| 白点抖动分析工具 JA0：jitter_report 四面板 + 分 quality 指标（56k 帧实测验证） | skills/aim-jitter-analysis，aim-jitter-analysis-plan §1 |
| 传输层 TLV 迁移 P0–P3：单连接复用 9100、旧链路拆除 | ADR-011，transport-26-plan |
| TLV 防阻塞 P0（CapturePipeline 有界背压）+ P1 Step 1（回传 pacing 12MB/s） | tlv-blocking-optimization-plan |
| fast 时敏通道（localAim 独立连接躲 HoL 阻塞）+ MarkerDetector prefilter 预筛 | ADR-017，commit c3c442c |
| 扫码途中连上 scanning 卡死修复 + 配对按钮合并 | commit a794810 |
| 速率 B1：P0 Release 固化（a99d940，三段真机验收过）+ P1 无检出降频入库（c3c442c） | update-rate-optimization-plan §1/§2（**P1 已被 CR plan 判回退，见 J1**） |
| 对焦 P0：AF 收敛后锁定 lensPosition + 恶化自动解锁重 AF | ADR-018，commit 822dc16；真机部署冒烟过，命中率/σ 正式对照待补 |
| 数码变焦双输入：二指手势（0.1× 磁滞吸附 + 刻度触觉）+ 轮盘（扳机门控），1×–3× | ADR-019，commit f8b8ae0，真机手感验收过 |
| IMU WP-I1 代码（MotionSampler 100Hz + meta.jsonl 落盘） | imu-fusion-plan §1；录制中断于手机散热 |

### 未完成 ⏳（即本路线图调度对象）

| 编号 | 事项 | 所属子 plan | 状态要点 |
|---|---|---|---|
| J1 | 恒定回报率 CR0 → CR2（识别解耦 + busy 闸门）→ CR1（移除 P1 主动降频） | [constant-report-rate-plan.md](constant-report-rate-plan.md) | **防抖最高优先**；吸收 update-rate P2。前提偏差：plan 假设 P1 未提交，实际已入库（c3c442c），CR1 = 删除已合入代码 |
| J2 | JA1：localAim 加 ts/pts 字段 + Mac 端 500ms 超龄丢弃 | [aim-jitter-analysis-plan.md](aim-jitter-analysis-plan.md) §2 | 双端小改动，协议只加不删；与 J1 同文件（CameraStreamer），串行 |
| J3 | JA2：stable/daily/fast 三档预设 A/B 实验 | aim-jitter-analysis-plan §3 | 用户跑动作脚本，agent 出报告；分 quality 分析依赖 J2 的新列。JA3（指标日常化）可选暂缓 |
| U1 | update-rate P3（降采样 bench）→ P4（30fps） | [update-rate-optimization-plan.md](update-rate-optimization-plan.md) §4/§5 | P0 ✅；P1 已入库但待 J1 回退；P2 被 J1 吸收，不再单列 |
| U2 | tlv-blocking P2：iOS 发送侧弱网丢帧闸门（videoInFlight） | [tlv-blocking-optimization-plan.md](tlv-blocking-optimization-plan.md) §3 | 待实施；J1 之后（同文件 CameraStreamer/TLVTransport） |
| U3 | whitedot-latency WP-L2：识别/上报提频 15→30Hz 评估 | [whitedot-latency-plan.md](whitedot-latency-plan.md) §2 | **与 U1 的 P4 是同一件事**——并入 P4 验收，不单独做 |
| U4 | IMU WP-I1 续跑（录制被散热中断）→ WP-I2（Mac 显示段 IMU 外推）→ WP-I3（识别段传播，评估门控） | [imu-fusion-plan.md](imu-fusion-plan.md)、[imu-wp-i1-resume-prompt.md](imu-wp-i1-resume-prompt.md) | 代码就绪，差录制与分析 |
| U5 | positioning Phase 2：Vision DataMatrix 检测器 A/B + MarkerTracker 补间 | [positioning-optimization-plan.md](positioning-optimization-plan.md) §7.5–7.6 | 识别质量扩展，门控式（A/B 不达标不切主通道） |
| U6 | liquid-cursor WP1–WP3：磁吸 / 形态 morph / 液滴融合 | [liquid-cursor-plan.md](liquid-cursor-plan.md) | 纯体验层，方案就绪 |
| U7 | focus-dial P1.5 点按对焦 + 对焦框 UI | [focus-dial-plan.md](../focus-dial-plan.md)、[focus-dial-activation-prompt.md](focus-dial-activation-prompt.md) | P0 与变焦已完成；本项让位于防抖簇。P1 轮盘对焦微调暂缓（轮盘已被变焦占用）；P2 refocus 协议等 P0 实测数据 |
| U8 | 扳机短按魔改 = 鼠标左键单击 | 本文件 B8（设计要点已成型，见激活提示词） | 可行性已确认：扳机走 `.button(id:pressed:)` 通道，按下/松开边沿可捕获（GimbalManager pressedButtons/triggerHeld 与上屏日志为证）。关键取舍：短按 <0.3s = 单击，按住 = 修饰键不变（否则按住+轮盘变焦会在 Mac 上左键长按拖选） |
| — | positioning Phase 3 / WP-L3：UDP 结果通道 | 两 plan 重叠 | **维持暂缓**：TLV+fast 通道已覆盖时敏需求，等 P4 30fps 实测后再评审 |
| — | wifi-aware-pairing | ADR-012 已终止 WA 通道 | 搁置：扫码 + Bonjour 自动发现够用 |

### 工作区卫生

2026-08-18：代码侧干净（822dc16 / f8b8ae0 / b130ef1 已入库）。
仍有两个疑似 Finder 误复制的垃圾项待用户确认后清理：
`ios/AimPhone 2.xcodeproj/`、`ios/AimPhone/Info 2.plist`（后者会被打进 .app 资源，
虽无害但属污染）。

## 1. 优先级与批次

| 批次 | 内容 | 子 plan 依据 | 预计真机回归 |
|---|---|---|---|
| **D1 防抖·恒定回报率** | CR0 核实 → CR2 识别解耦 + busy 闸门（吸收 update-rate P2）→ CR1 移除 P1 主动降频 | constant-report-rate-plan（验收门 §6） | 捂黑恢复/跳变/CPU 表 + Debug 捂黑反向验证 |
| **D2 防抖·数据基础** | JA1：localAim 加 ts/pts（只加不删）+ Mac 500ms 超龄丢弃 | aim-jitter-analysis-plan §2 | 新 CSV 带 ts/pts/quality，jitter_report 分层有输出 |
| **D3 防抖·实验** | JA2：stable/daily/fast 三档 A/B（用户跑动作脚本，agent 出报告） | aim-jitter-analysis-plan §3 | —（纯数据分析） |
| **B2′ 速率·弱网** | tlv-blocking P2 发送侧 videoInFlight 闸门（原 B2 的识别解耦已被 D1 吸收，剔除） | tlv-blocking-plan §3 | Network Link Conditioner 弱网档 |
| **B3 速率·提频** | update-rate **P3**（降采样，bench 门控）→ **P4**（30fps，吸收 WP-L2 评估） | update-rate-plan §4/§5；whitedot-latency-plan §2 验收门并入 | + bench A/B + 10 分钟热稳定 |
| **B4 IMU 融合** | WP-I1 续跑录制/分析 → WP-I2 显示段 IMU 外推 →（数据达标才）WP-I3 | imu-fusion-plan；续跑提示词已备好 | 按 imu-fusion-plan §4 总验收 |
| **B5 识别质量扩展** | positioning Phase 2.1 Vision A/B → 2.2 MarkerTracker（各自门控） | positioning-optimization-plan §7.5–7.6 | A/B 双通道各录 5 分钟 |
| **B6 交互体验** | liquid-cursor WP1–WP3 | liquid-cursor-plan §2 | 视觉走查为主 |
| **B7 交互·对焦** | focus-dial P1.5 点按对焦 + 对焦框 UI | focus-dial-plan §P1.5 | 真机冒烟四项（竖屏/横屏/扫码中/变焦态） |
| **B8 交互·扳机单击** | 扳机短按 = 鼠标左键单击（按住仍为修饰键） | 本文件 U8；提示词在 master-activation-prompt.md | 短按出单击 / 按住不触发 / 按住+轮盘变焦不拖选 |

**依赖关系**：D1→D2 严格顺序（同改 CameraStreamer.localizeFrame，且 CR1 先行消除
降频对 JA1 攒批率指标的污染）；D3 依赖 D2 的新列做分 quality 分析；
B2′ 在 D1 之后（CameraStreamer/TLVTransport 同文件链式）；B3 在 B2′ 后；
B4 与 D/B 簇无代码冲突，可穿插（利用真机录制等待时间）；B5/B6/B7 在防抖+速率
收口后启动。

**防抖簇收口标准**（D1–D3 全部完成后应达到）：
0 检出段 localAim 间隔恒定 p50 ≈ 66ms；捂黑恢复白点重现 ≤250ms 且恢复窗跳变 ≤1 帧；
JA2 验收门（stable 档静止 p95 ≤ 2pt；fast 档横扫跳变 ≤ daily 1.2 倍）；
超龄丢弃计数强网基线 ≈ 0。

**速率簇收口标准**（B2′/B3 完成后应达到）：
Release 构建下 localAim 速率 ≥ 15Hz（P4 达标则 30Hz）、detect_ms 中位 ≤ 20ms
（P3 达标则 ≤ 10ms）、弱网下推流不淤积（0 检出 CPU 自限由 D1 busy 闸门承担）。

## 2. ADR 编号预留

decisions.md 现有最大号 ADR-019（变焦双输入）。后续：**ADR-020** = 恒定回报率原则
（D1 验收后落，constant-report-rate-plan 文中的"ADR-019"引用一律作废改 020）；
ADR-021+ 按批推进（JA1 若产生协议层决策、P3/P4 达标、WP-I2、Vision A/B 结论等
各记一条）。一律以 decisions.md 实际最大号为准顺延。

## 3. 全局硬约束（所有批次继承）

- 不改 TLV 线上消息格式；协议字段只加不删，保持向后兼容
- 不改 UI 布局与交互（B6/B7 除外，且分别以 liquid-cursor-plan / focus-dial-plan 为限）
- 注释遵循 comment-style.md；像素数据不进主线程；串行队列约定不破坏
- 每阶段：`swift build && swift run ScreenAim --self-test`；
  iOS 改动后 `cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj
  -scheme AimPhone -destination 'generic/platform=iOS' build`（签名失败可接受）
- 每阶段独立 commit（message 写明实测 vs 门槛）、单文件级可回退
- 实测数据注明机型/系统/标记尺寸/构建配置（docs 维护约定 ④）
- 真机回归基线（每批次后）：配对 → 标定下发 → 白点（含边角仿射兜底）→
  鼠标三键+滚轮 → 断开兜底 → 采集回传；对焦锁定与变焦手感冒烟（ADR-018/019 后新增）
