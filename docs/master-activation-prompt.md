# ScreenAim 总路线图 · 激活提示词

> 用法：进入项目目录后，按批次把对应「提示词正文」整段发给 kimi cli，**一批一验**，
> 验收通过再发下一批。批次顺序与优先级定义见 [master-plan.md](master-plan.md)。
> 本文件是总入口；update-rate-activation-prompt.md 等子提示词仍有效，但批次划分以本文件为准
> （B1 比子版多了"先收尾提交未提交改动"一步）。

---

## 批次 B1（速率·速效：P0 Release 固化 → P1 无检出降频）——进行中，用续跑提示词

> 2026-08-18 进度：B1 第 0 步收尾提交（c3c442c）与插入批（a794810 扫码修复 +
> 配对按钮合并）已入库；P0 代码/文档已落地未提交（待三段验收）；P1 未动。
> **续跑直接用 [update-rate-activation-prompt.md](update-rate-activation-prompt.md)
> 的「第一批（续跑）提示词」**，内容覆盖：P0 三段验收（静止/横扫/贴边角分别
> 录制）→ P0 commit → P1 实施与验收 → P1 commit → docs 同步与 B2 准备情况。
> 原 B1 提示词（收尾提交 + P0 + P1 全量）已被实际执行覆盖，仅存档于 git 历史。

---

## 批次 B2（速率·结构：update-rate P2 识别解耦 + tlv-blocking P2 发送侧丢帧闸门）

```text
# 任务：ScreenAim 总路线图 B2（速率优化·结构批）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：B1 已完成并验收（Release 固化 + 无检出降频已上线）。
两个改动同处 CameraStreamer/TLVTransport，一次真机回归覆盖，故并批。

## 动手前必读
1. docs/update-rate-optimization-plan.md §3（识别解耦改动清单）
2. docs/tlv-blocking-optimization-plan.md §3（发送侧 videoInFlight 闸门改动清单）
3. docs/comment-style.md、docs/architecture.md 线程模型
4. 对照实现：Sources/ScreenAim/main.swift 的 frameInFlight busy 闸门段（同构参考）

## 执行内容
1. update-rate P2（ios/AimPhone/CameraStreamer.swift）：
   - 新增 localizeQueue（"aimphone.localize"），localizeFrame 异步化；
     busy 闸门（NSLock + localizeInFlight）处理中丢弃新识别请求不排队
   - CVPixelBuffer 跨队列 retain/release（WARNING：漏 release = 帧池耗尽卡死采集）
   - captureRecorder.record 随迁；录制期 PNG 编码占用 localizeQueue 的取舍写 NOTE
   - JPEG 编码/发送/framesSent、未连接扫码分支留 videoQueue 不动
2. tlv-blocking P2（ios/AimPhone/TLVTransport.swift + CameraStreamer 计数接线）：
   - send(jpeg:) 改 videoInFlight 闸门 + 可丢帧异步发送；videoDropped 计数接进
     CameraStreamer 现有状态日志；注释写清"视频可丢、控制/采集不动"
   - 顺序性说明：单连接视频发送任一时刻至多一条在途，TLV framer 保消息原子性

## 硬约束与验收（继承 master-plan §3，另加）
- 真机 Release：视频有效帧率 ≥ 14fps，localAim 到达间隔 p50 ≤ 130ms
- Debug 构建反向验证一次：localAim 降速但视频帧率基本不受影响（解耦直接证据），
  验证完切回 Release，数据写验收小结
- 弱网实测（Network Link Conditioner 3G/Edge 档）：编码回调周期不漂移、
  videoDropped 随档位上升而 framesSent 不淤积、网络恢复 1s 内回满帧率；
  强网回归 videoDropped ≈ 0
- 内存观察 3 分钟平坦（无帧池泄漏）
- 两个改动各一个 commit，message 写明实测 vs 门槛

## 交付物
改动文件清单、验收小结（含 Debug 反向验证 + 弱网数据）、ADR-018（手机端识别
调度 + 发送侧丢帧闸门，写明 2026-08-18 实测依据）、docs/architecture.md 线程模型、
docs/modules.md 同步、tlv-blocking-optimization-plan.md 状态头更新（P2 完成）。
```

---

## 批次 B3（速率·提频：update-rate P3 降采样 bench → P4 30fps，吸收 WP-L2）

```text
# 任务：ScreenAim 总路线图 B3（速率优化·提频批）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：B1/B2 已完成并验收。本批吸收 whitedot-latency-plan WP-L2（15→30Hz 提频评估），
WP-L2 不再单独执行；WP-L3（UDP）维持暂缓。

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
（WP-L2 已并入验收）同步、ADR-018 追加或新 ADR-019。
```

---

## 批次 B4（IMU 融合：WP-I1 续跑 → WP-I2 → WP-I3 评估）

```text
# 任务：ScreenAim 总路线图 B4（IMU 融合）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：速率簇 B1–B3 已收口（或按 master-plan §1 与 B2/B3 穿插）。
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
前置：速率簇收口（B1–B3）。动手前重读 docs/positioning-optimization-plan.md
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
前置：B1–B3 收口（白点数据流稳定是磁吸手感的前提）。
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
