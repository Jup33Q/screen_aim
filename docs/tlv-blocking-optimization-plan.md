# TLV 数据流防阻塞优化方案（P0–P2）

> 状态：**P0、P1 Step 1 已完成**（CapturePipeline 有界管道 + 回传 pacing 12MB/s，
> tlv-upload-test / tlv-loopback 回归与回环争用实测通过；验收门余真机场景待测，
> Step 2 未启用）。P2 待实施。激活提示词见文末 §5。
> 前置阅读：[protocol.md](protocol.md) §11（线上 TLV 格式）、
> [transport-26-plan.md](transport-26-plan.md)（TLV 迁移主方案，本文是其防阻塞补强）、
> [comment-style.md](comment-style.md)、
> [skills/network-framework-tlv](../skills/network-framework-tlv/SKILL.md)。
> 约束：全程基于 Network.framework 26+ 结构化并发 API（NetworkListener /
> NetworkConnection + 内置 TLV framer），不引入第三方网络库，不改 TLV 线上格式
> （P1 备选路径例外，见 §3.3）。

## 0. 问题清单与根因

| # | 现象 | 根因 | 位置 |
|---|---|---|---|
| ① | 采集回传期间视频帧/控制消息被磁盘 I/O 卡住 | `CaptureIngestor.process` 的 `bin.write(to:)`（每张 PNG 数百 KB～MB 级同步写盘）**内联在 `for try await message in conn.messages` 接收循环里**，写盘期间整个循环停摆 | `Sources/ScreenAim/FrameServerV2.swift` `handleConnection` → `dispatch` → `CaptureIngestor.process` |
| ② | 回传大流量与视频/控制挤一条 TCP，字节级队头阻塞（HOL） | 单连接复用是 ADR-011 的既定架构，但 35–75MB/段的 PNG 流会把后面的 mouseUp 等控制消息压在发送缓冲里（transport-26-plan §「回传争用」风险项，当时标注"推测无，未实测"） | iOS `TLVTransport.uploadCapture` ⇄ Mac `FrameServerV2`，整条链路 |
| ③ | 弱网下手机端发送侧无丢帧闸门，编码管线可能被拖 | 视频发送走 `sendIdempotent` 尽力语义，无背压信号回传编码侧；弱网时框架内部若排队，发送侧无感知、无丢弃策略 | `ios/AimPhone/TLVTransport.swift` `send(jpeg:)` |

已具备、**不要动**的正确基础：`noDelay(true)`（Nagle 攒批实测修复）、
Mac 端视频帧 busy 闸门丢旧保新（main.swift `frameInFlight`）、5s×6 看门狗、
未知 type 忽略、断开兜底 mouseUp/disconnect + lastMessage（ADR-008）。

## 1. P0：采集落盘移出接收循环（有界管道 + 独立消费 Task）

**目标**：接收循环只做分帧路由；落盘在独立 Task 串行消费；缓冲满时挂起入队
即背压（TCP 窗口自然反压回手机端，手机端上传本来就是串行 `try await send`，
背压链路闭环）。

### 改动点（全部在 `Sources/ScreenAim/FrameServerV2.swift`）

1. 新增私有 `actor CapturePipeline`（文件内私有，不进 ScreenAimCore）：
   - 元素：`CaptureIngestor` 的入参二元组 `(obj: [String: Any], bin: Data)`
   - 容量 **8 条**（单条最大 ≈1MB JSON 上限 + PNG 数 MB，峰值内存可控在 ~50MB 内）
   - `func enqueue(_ item:) async`：深度 ≥ 容量时挂起（CheckedContinuation 排队），
     消费者每取一条唤醒一个等待者——**挂起即背压，禁止无界缓冲**
   - `func close()`：连接终结时调用，消费者排空剩余元素后退出
   - 实现形态建议：内部一个 `AsyncStream`（unbounded）做消费端迭代 +
     手动深度计数 + 挂起等待者队列；或纯 continuation 环形缓冲，二选一，
     以代码更短者为准
2. `handleConnection` 改造：
   - 创建 `CapturePipeline` + 消费 Task（`Task { for await item in pipe { ingestor.process(...) } }`）
   - `dispatch` 的 `captureMeta`/`captureFrame` 分支从同步 `ingestor.process`
     改为 `await pipe.enqueue(...)`——**type 10/11 必须同走一条管道**，
     session/frame/end 顺序由串行消费者保证（分开走会乱序：end 可能先于 frame 落盘）
   - `video`/`control` 分支保持内联不变（video 已在 main.swift 侧有 busy 闸门；
     control 是小 JSON，无重活）
   - `defer` 收尾顺序改为：`await pipe.close()` → 等消费 Task 退出 →
     `ingestor.finish()`（中途断连兜底语义不变，按已收帧数收尾）
3. `CaptureIngestor` 本体不改（线程约束注释更新：由"连接子任务独占"改为
   "消费 Task 独占"）。

### 关键风险与对策

| 风险 | 对策 |
|---|---|
| enqueue 挂起期间连接被 teardown，continuation 泄漏 | `close()` 必须唤醒全部等待者并使其返回（丢弃未入队元素）；Task 取消路径也要触发 close |
| 管道满 → 背压到手机端上传变慢 | 预期行为，正是设计目标；上传总时长由磁盘速度决定，不再转嫁为视频卡顿 |
| session/end 与 frame 乱序 | 单管道串行消费天然保序，测试覆盖（见验收②） |

### 验收

- ① `tools/tlv-upload-test` 跑 100 帧回传，同时 `tools/tlv-loopback` 或真机推流：
  视频消息到达间隔 P95 与无回传基线差 < 20%（在 `handleConnection` 加临时
  到达间隔统计日志，验收后保留为 `--verbose` 开关或删除）
- ② 回传落盘目录帧数、meta.jsonl 行数、session.json 与改造前一致（diff 校验）
- ③ 上传中途拔线：兜底 `finish()` 正常触发，session.json 帧数 = 实际落盘数

## 2. P1：回传与视频/控制的单连接争用（先实测，再分级治理）

**分两步走，以实测数据决定是否需要第二步。**

### 2.1 Step 1（首选，零协议改动）：发送侧 pacing

改动点：`ios/AimPhone/TLVTransport.swift` `uploadCapture` 的帧循环内——

1. 每条 `try await conn.send(...)` 之后 `await Task.yield()`，让视频帧/
   控制消息有插队窗口
2. 加简易限速：按 payload 字节数折算睡眠，目标速率常量
   `captureUploadRate = 12 * 1_000_000` B/s（约 12MB/s，局域网 Wi-Fi 典型
   带宽的 1/4～1/3，作为可调常量集中放在文件头部并注释实测依据）；
   `try? await Task.sleep(nanoseconds: UInt64(Double(payload.count) / rate * 1e9))`
3. 限速只在回传期间生效，不影响视频/控制正常路径

**验收门**：真机「回传同时推流 + 鼠标点击」场景——
- 回传期间控制消息（mouseDown→Mac 日志时间戳）追加延迟 < 20ms
- 视频有效帧率 ≥ 13fps（Mac 端 main.swift 现有帧率统计）
- 100 帧回传总时长劣化 ≤ 30%（限速的合理代价）

达标即 P1 收工，**不做 Step 2**。

### 2.2 Step 2（备选，Step 1 不达标才启用）：回传退回独立连接

transport-26-plan 已预留此退路（"劣化则退回独立端口，TLV 栈不变，改动极小"）：

- Mac：`FrameServerV2` 增加第二个 `NetworkListener`（servePort+1，不发布 Bonjour），
  type 10/11 路由逻辑与 `CaptureIngestor` 原样复用（每连接独立 ingestor 的
  现有设计天然支持）；主连接收到 type 10/11 仍可处理（向后兼容旧手机）
- iOS：`TLVTransport.uploadCapture` 改为临时建立第二条 `NetworkConnection`
  到 port+1，上传完即断开；主连接零改动
- 文档：protocol.md §11 补"采集回传独立端口"段落，标注触发条件与 ADR 记录；
  decisions.md 记一条（这是对 ADR-011 ④"回传并入主连接"的局部修订，必须写明
  实测数据依据）

## 3. P2：发送侧弱网丢帧闸门（iOS）

**目标**：视频发送从"无感知尽力发"改为"有背压信号的可丢帧发送"，与 Mac 端
main.swift 的 busy 闸门形成双端对称的丢旧保新策略。

改动点：`ios/AimPhone/TLVTransport.swift`——

1. `send(jpeg:)` 从 `sendIdempotent` 改为带闸门的异步发送：
   - `videoInFlight` 标志（NSLock 保护，或并入既有状态管理）；
     置位时新帧**直接丢弃**并 `videoDropped += 1`
   - 未置位则置位，`Task { try? await conn.send(jpeg, type: video); 复位 }`
   - 语义注释：视频帧可丢，控制/采集仍走原路径不动
2. 计数暴露：`framesSent`（CameraStreamer 已有）旁加 `videoDropped`，
   接进现有状态日志/UI 调试信息（与 framesSent 同处）
3. 顺序性说明：单连接上视频发送任一时刻只有一条在途（闸门保证），与
   控制/采集的并发 send 由 TLV framer 保证消息原子性（框架契约），
   不产生半消息交织

**验收（弱网实测）**：Network Link Conditioner 加 3G/Edge 档位——
- 手机端编码线程帧率稳定（Camera 采集回调周期不随网络劣化漂移）
- `videoDropped` 随弱网档位上升、`framesSent` 不淤积，内存平坦
- 网络恢复后 1s 内视频流恢复满帧率
- 强网回归：`videoDropped` ≈ 0，与改造前行为一致

## 4. 实施顺序与影响面

| 顺序 | 阶段 | 影响文件 | 文档同步 |
|---|---|---|---|
| 1 | P0 | `Sources/ScreenAim/FrameServerV2.swift` | 本文件状态头；modules.md 的 FrameServerV2 条目补一句"采集落盘经有界管道异步消费" |
| 2 | P1 Step 1 → 验收门 →（必要时）Step 2 | `ios/AimPhone/TLVTransport.swift`（Step 1）；+ `Sources/ScreenAim/FrameServerV2.swift`（Step 2） | Step 2 触发时才改 protocol.md §11 / decisions.md |
| 3 | P2 | `ios/AimPhone/TLVTransport.swift`、`ios/AimPhone/CameraStreamer.swift`（计数接线） | modules.md 发送路径条目补 busy 闸门说明 |

- 全程不改 TLV 线上格式（仅 P1 Step 2 增加端口级分流，消息格式不变）
- 每阶段独立验收、独立可回退（单文件级 diff）
- 真机回归基线：连接/扫码配对/标定下发/鼠标点击/断开兜底/采集回传全流程
  （同 transport-26-plan P1/P3 验收清单）

## 5. 激活提示词

```
激活 docs/tlv-blocking-optimization-plan.md。先完整读该 plan、docs/protocol.md §11、
docs/comment-style.md，再读 Sources/ScreenAim/FrameServerV2.swift、
ios/AimPhone/TLVTransport.swift、ios/AimPhone/CameraStreamer.swift 和
Sources/ScreenAim/main.swift 的 frameInFlight 段。

按 plan §4 顺序实施，一次只做一个阶段，每阶段完成后停下来汇报：
1. P0：FrameServerV2 加文件内私有 actor CapturePipeline（容量 8，enqueue 挂起
   即背压，close 排空并唤醒全部等待者），type 10/11 改走管道，defer 收尾顺序
   close → 消费 Task 退出 → ingestor.finish()。CaptureIngestor 本体逻辑不改，
   只更新线程约束注释。改完跑 tools/tlv-upload-test 验证落盘结果与改造前一致。
2. P1 Step 1：uploadCapture 帧循环内每条 send 后 Task.yield() + 按字节折算的
   限速睡眠（速率常量 12MB/s 集中文件头部，注释写清依据）。改完用
   tools/tlv-upload-test + tlv-loopback 做并发争用实测，汇报数据，由我决定
   是否进 Step 2——不要自作主张做 Step 2。
3. P2：send(jpeg:) 改 videoInFlight 闸门 + 可丢帧异步发送，丢弃计数接进
   CameraStreamer 现有状态日志。语义注释写清"视频可丢、控制/采集不动"。

硬约束：只用 Network.framework 26+ API，不改 TLV 线上消息格式，不引入新依赖；
注释遵循 comment-style.md（NOTE: 标注语义/等价物/推翻条件）；每阶段保持
单文件级可回退 diff；断开兜底（mouseUp all + disconnect + lastMessage）和
看门狗语义一律不许动。
```
