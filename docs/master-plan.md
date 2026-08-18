# ScreenAim 总实施路线图（Master Plan）

> 日期：2026-08-18 · 定位：各子 plan 的**调度层**——只排优先级与批次，改动细节、
> 验收门一律以被引用的子 plan 为准，本文不复制。
> 优先级（用户 2026-08-18 指定）：**网络与识别速率优化 > IMU 融合 > 识别质量扩展 > 交互体验**。
> （覆盖 positioning-optimization-plan 原「识别质量 > 传输速度」排序——速率簇的 P3/P4
> 仍以不劣化识别质量为验收门，两排序在验收层合一。）
> 激活提示词：[master-activation-prompt.md](master-activation-prompt.md)。

## 0. 项目进度盘点（2026-08-18，以 commit / ADR / 实测为准）

### 已完成 ✅

| 事项 | 出处 |
|---|---|
| 定位 Phase 0/1.1–1.3：8 标记冗余 + RANSAC、亚像素精化、One Euro 滤波 | ADR-007，positioning-optimization-plan |
| 边角定位修复 WP1/WP3：3 点仿射兜底 + 断帧滑行 + 滤波三层增强 + 调参面板 | ADR-013/014，edge-localization-and-filter-plan |
| 白点滞后 WP-L1：Mac 显示段 60Hz 匀速死推算外推 | ADR-015，whitedot-latency-plan |
| 传输层 TLV 迁移 P0–P3：单连接复用 9100、旧链路拆除 | ADR-011，transport-26-plan |
| TLV 防阻塞 P0（CapturePipeline 有界背压）+ P1 Step 1（回传 pacing 12MB/s） | tlv-blocking-optimization-plan |
| fast 时敏通道（localAim 独立连接躲 HoL 阻塞）+ MarkerDetector prefilter 预筛 | ADR-017，commit c3c442c（2026-08-18 收尾提交，真机冒烟通过） |
| 扫码途中连上 scanning 卡死修复 + 配对按钮合并（扫码/Mac二维码开关合一） | commit a794810（B1 期间用户插入批，真机三项验证通过） |
| IMU WP-I1 代码（MotionSampler 100Hz + meta.jsonl 落盘） | imu-fusion-plan §1；录制中断于手机散热 |

### 未完成 ⏳（即本路线图调度对象）

| 编号 | 事项 | 所属子 plan | 状态要点 |
|---|---|---|---|
| U1 | update-rate P0–P4（Release 固化 / 无检出降频 / 识别解耦 / 降采样 bench / 30fps） | [update-rate-optimization-plan.md](update-rate-optimization-plan.md) | **B1 进行中**：P0 固化已落地（project.yml scheme，showBuildSettings=-O 已验证；即兴实测 Release det 中位 9.8ms/30Hz），待真机三段验收（静止/横扫/贴边角分别录制）后提交；P1 未动；P2–P4 待实施 |
| U2 | tlv-blocking P2：iOS 发送侧弱网丢帧闸门（videoInFlight） | [tlv-blocking-optimization-plan.md](tlv-blocking-optimization-plan.md) §3 | 待实施；与 U1 的 P2 同文件（CameraStreamer/TLVTransport），宜同批 |
| U3 | whitedot-latency WP-L2：识别/上报提频 15→30Hz 评估 | [whitedot-latency-plan.md](whitedot-latency-plan.md) §2 | **与 U1 的 P4 是同一件事**——并入 P4 验收，不单独做 |
| U4 | IMU WP-I1 续跑（录制被散热中断）→ WP-I2（Mac 显示段 IMU 外推）→ WP-I3（识别段传播，评估门控） | [imu-fusion-plan.md](imu-fusion-plan.md)、[imu-wp-i1-resume-prompt.md](imu-wp-i1-resume-prompt.md) | 代码就绪，差录制与分析 |
| U5 | positioning Phase 2：Vision DataMatrix 检测器 A/B + MarkerTracker 补间 | [positioning-optimization-plan.md](positioning-optimization-plan.md) §7.5–7.6 | 识别质量扩展，门控式（A/B 不达标不切主通道） |
| U6 | liquid-cursor WP1–WP3：磁吸 / 形态 morph / 液滴融合 | [liquid-cursor-plan.md](liquid-cursor-plan.md) | 纯体验层，方案就绪 |
| — | positioning Phase 3 / WP-L3：UDP 结果通道 | 两 plan 重叠 | **维持暂缓**：TLV+fast 通道已覆盖时敏需求，等 P4 30fps 实测后再评审 |
| — | wifi-aware-pairing | ADR-012 已终止 WA 通道 | 搁置：扫码 + Bonjour 自动发现够用 |

### 未提交工作区改动（任何批次动手前先处理）

2026-08-18 B1 收尾提交（c3c442c）已完成，工作区代码侧干净。当前未提交仅
P0 固化的 3 个文件（`ios/project.yml`、`docs/development.md`、`README.md`）——
**故意挂起**：P0 commit 需真机三段验收数据写进 message，验收随下一批执行。
另有两个疑似 Finder 误复制的垃圾项待用户确认后清理：`ios/AimPhone 2.xcodeproj/`、
`ios/AimPhone/Info 2.plist`（后者会被打进 .app 资源，虽无害但属污染）。

## 1. 优先级与批次

| 批次 | 内容 | 子 plan 依据 | 预计真机回归 |
|---|---|---|---|
| **B1 速率·速效** | 收尾提交未提交改动（ADR-017/prefilter 验收）→ update-rate **P0**（Release 固化）→ **P1**（无检出降频） | update-rate-plan §1/§2 | 配对/白点/鼠标/采集回传基线 |
| **B2 速率·结构** | update-rate **P2**（识别挪出采集队列）+ tlv-blocking **P2**（发送侧 videoInFlight 闸门） | update-rate-plan §3；tlv-blocking-plan §3 | + Network Link Conditioner 弱网档 |
| **B3 速率·提频** | update-rate **P3**（降采样，bench 门控）→ **P4**（30fps，吸收 WP-L2 评估） | update-rate-plan §4/§5；whitedot-latency-plan §2 验收门并入 | + bench A/B + 10 分钟热稳定 |
| **B4 IMU 融合** | WP-I1 续跑录制/分析 → WP-I2 显示段 IMU 外推 →（数据达标才）WP-I3 | imu-fusion-plan；续跑提示词已备好 | 按 imu-fusion-plan §4 总验收 |
| **B5 识别质量扩展** | positioning Phase 2.1 Vision A/B → 2.2 MarkerTracker（各自门控） | positioning-optimization-plan §7.5–7.6；原「第二批提示词」在 plan-activation-prompt.md | A/B 双通道各录 5 分钟 |
| **B6 交互体验** | liquid-cursor WP1–WP3 | liquid-cursor-plan §2 | 视觉走查为主 |

**依赖关系**：B1→B2→B3 严格顺序（同文件链式改动）；B4 与 B1–B3 无代码冲突，
可与 B2/B3 之间穿插（利用真机录制等待时间）；B5/B6 在速率簇收口后启动；
B5 的 UDP（Phase 3）不在本路线图内。

**速率簇收口标准**（B1–B3 全部完成后应达到）：
Release 构建下 localAim 速率 ≥ 15Hz（P4 达标则 30Hz）、detect_ms 中位 ≤ 20ms
（P3 达标则 ≤ 10ms）、0 检出场景 CPU 占用自限、弱网下推流不淤积。

## 2. ADR 编号预留

decisions.md 现有最大号 ADR-017。后续：**ADR-018** = 手机端识别调度
（Release 固化 + 队列解耦 + 无检出降频，B1/B2 验收后落）；ADR-019+ 按批推进
（P3/P4 达标、WP-I2、Vision A/B 结论等各记一条）。注意 plan-activation-prompt.md
旧文提到「顺延为 ADR-012/013」已被实际占用作废，一律以 decisions.md 实际最大号为准。

## 3. 全局硬约束（所有批次继承）

- 不改 TLV 线上消息格式；协议字段只加不删，保持向后兼容
- 不改 UI 布局与交互（B6 除外，且以 liquid-cursor-plan 为限）
- 注释遵循 comment-style.md；像素数据不进主线程；串行队列约定不破坏
- 每阶段：`swift build && swift run ScreenAim --self-test`；
  iOS 改动后 `cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj
  -scheme AimPhone -destination 'generic/platform=iOS' build`（签名失败可接受）
- 每阶段独立 commit（message 写明实测 vs 门槛）、单文件级可回退
- 实测数据注明机型/系统/标记尺寸/构建配置（docs 维护约定 ④）
- 真机回归基线（每批次后）：配对 → 标定下发 → 白点（含边角仿射兜底）→
  鼠标三键+滚轮 → 断开兜底 → 采集回传
