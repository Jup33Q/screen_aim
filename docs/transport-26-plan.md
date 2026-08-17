# 传输层整体迁移方案（iOS 26 / macOS 26+ 专属修订版）

> 状态：实施中（2026-08-17 激活）。P0 尖刺结论：①②通过；③**不过**——Wi-Fi Aware
> 在 macOS 不可用（Xcode 26.6 SDK 全符号 `@available(macOS, unavailable)`，系统框架为空壳），
> WA 通道终止，降级为 **TLV + Bonjour 主路径**（详见 ADR-012）。P2 阶段整体搁置，
> 其余按本文执行，本文所有 WA 相关内容仅作恢复时的设计底稿。
> 本文是 [tlv-migration-plan.md](tlv-migration-plan.md) 与
> [wifi-aware-pairing-plan.md](wifi-aware-pairing-plan.md) 在**新部署前提**下的复审合并版，
> 两原文档保留为调研背景，实施以本文为准。
> 前置阅读：[protocol.md](protocol.md)（现行线上格式）、
> [skills/network-framework-tlv](../skills/network-framework-tlv/SKILL.md)、
> [skills/wifi-aware-pairing](../skills/wifi-aware-pairing/SKILL.md)、
> [comment-style.md](comment-style.md)。

## 1. 复审前提与结论

**新前提（用户指定）**：目标部署机全部在 iOS 26 / macOS 26 以上。

这一前提抽掉了原两份方案里最保守设计的地基——原方案的"双栈并行、旧链路冻结、
Wi-Fi Aware 只做第三通道"都是为了兼容现场可能存在的 <26 客户端。前提变更后复审结论：

1. **传输内容最大化交给框架**：分帧、消息边界、背压、编解码、加密、发现、配对、
   并发模型全部移交 Network.framework / Wi-Fi Aware，手工代码只保留业务语义层
   （消息内容、CSV 日志、断开兜底语义）。
2. **Wi-Fi Aware 从第三通道升为首选通道**（用户明确指示）：无路由器、免本地网络
   授权弹窗、datapath 强制加密三项收益在全 26+ 前提下全额兑现。
3. **旧手工分帧链路（9100 / `[4B 长度]` / LegacyTransport）在 V2 回归通过后拆除**——
   这是项目"只加不删"兼容文化（protocol.md §6/§7）的首次例外，理由与推翻条件记入
   ADR-011。过渡期仍按原 TLV 方案双服务并行一个版本周期。

## 2. 传输内容全量盘点与框架归属

| # | 传输内容 | 现状（手工） | 复审后归属 | 手工代码残留 |
|---|---|---|---|---|
| 1 | 发现 | Bonjour `_aimphone._tcp` 浏览/发布 | **Wi-Fi Aware NAN 发现**（首选）；Bonjour `_aimphone2._tcp`（同网备用） | 无 |
| 2 | 配对 | 扫码 / 手工输 IP（每次） | **Wi-Fi Aware 系统配对**（DevicePicker，一次永久） | 扫码/手工 IP 永久兜底 |
| 3 | 视频帧分帧 | `[4B 大端长度][JPEG]` + 16MB 上限检查 | **TLV framer type 0**（框架拼包/拆包/长度校验） | 无 |
| 4 | 控制帧分帧 | 长度字最高位当"控制"标志位 | **TLV framer type 1**（type 路由替代位打包） | 无 |
| 5 | 控制消息编解码 | `JSONSerialization` + `[String: Any]` | 首版维持 JSON（最小 diff）；**Coder(AimMessage) 预留为 type 2**（P3 评估） | JSON 字符串构造 |
| 6 | 采集回传 | 第二条 TCP（port+1）+ `[4B jsonLen][json][4B binLen][bin]` + readExact 链 | **并入主 TLV 连接** type 10/11，复合 payload 一次传递；撤销第二端口 | 无 |
| 7 | 并发/生命周期 | 回调地狱 + 每回调 `[weak self]` | **async/await 结构化并发**，Task 取消即连接取消 | 无 |
| 8 | 流控背压 | `contentProcessed` 完成回调 | **`try await send` 挂起即背压**（15fps 视频天然节流） | 无 |
| 9 | 加密 | 局域网明文 | **Wi-Fi Aware datapath 强制加密**（白得，不可关）；Bonjour 备用路径可叠 `TLV { TLS() }`（可选，P3 评估） | 无 |
| 10 | 本地网络授权弹窗卡死 | 5s 看门狗 + 6 次重试 | **WA 通道不走局域网子系统，问题消失**；仅 Bonjour/扫码备用路径保留看门狗（`withThrowingTaskGroup` 超时竞争） | 备用路径看门狗 |
| 11 | UDP 结果通道（protocol §9 预留，Phase 3） | 未实施 | **NetworkConnection UDP**（自带消息边界，不需 TLV） | 无 |
| 12 | 断开兜底语义 | `mouseUp all` + `disconnect` + finalMessage | 保留为 TLV type 1 控制消息（**语义层，框架不托管**，ADR-008 不变） | 全量保留 |

**维持不变的语义层**（与传输升级正交）：calib 下发时机与 JSON 格式、鼠标事件语义、
pairingQR 推送、二维码 payload 结构、CSV 日志格式（`src` 列新增 `tlv`/`wa` 取值）、
视频编码（JPEG→HEVC 不在本方案范围）。

## 3. 目标拓扑

```
iPhone（AimPhone）                                    Mac（ScreenAim）
┌──────────────────────────────────────────────────────────────────┐
│ 一次性系统配对：iPhone DevicePicker（系统 UI）⇄ Mac WA publisher     │
├──────────────────────────────────────────────────────────────────┤
│ 单一 TLV 连接承载全部流量：                                          │
│   type 0  = 视频帧 JPEG（iPhone→Mac，≈15fps）                       │
│   type 1  = 控制 JSON（双向：calib/pairingQR/captureStart↓，         │
│             localAim/mouse*/disconnect/capture 状态↑）              │
│   type 2  = （预留）Coder(AimMessage) 信封枚举，P3 评估启用           │
│   type 10 = 采集记录 session/end JSON                                │
│   type 11 = 采集记录 frame（[4B jsonLen][json][PNG] 复合 payload）    │
├──────────────────────────────────────────────────────────────────┤
│ 通道优先级（高→低）：                                                │
│  ① Wi-Fi Aware：NetworkBrowser(.wifiAware) → NetworkConnection     │
│     协议栈 TLV（datapath 已强制加密，无需再叠 TLS）                   │
│     .realtime + .serviceClass(.interactiveVideo)                   │
│  ② Bonjour _aimphone2._tcp（同局域网备用）：TLV { TCP() }            │
│  ③ 扫码/手工 IP（永久兜底）：TLV { TCP() } 同协议栈                   │
└──────────────────────────────────────────────────────────────────┘
```

- 角色维持：Mac = listener/publisher，iPhone = connector/subscriber。
- 三通道共用**同一套 TLV 消息分发代码**——Wi-Fi Aware 连上后就是普通
  NetworkConnection，通道差异只存在于"拿到连接"这一步。
- UDP 结果通道（Phase 3 时）独立于上图，走 NetworkConnection UDP，latest-wins。

## 4. 相对原两份方案的修订点（复审 diff）

| # | 原方案设计 | 复审修订 | 理由 |
|---|---|---|---|
| 1 | TLV 方案 §3：9100 手工分帧 + 9102 TLV **双服务永久并行** | 过渡期双服务一个版本周期，V2 真机回归通过后**删除 9100 与手工分帧代码**，收敛为单服务 | 现场无 <26 客户端；手工帧与 TLV 头不兼容，永久并行是永久维护负担 |
| 2 | iPhone 部署目标 17.0，全部新代码 `if #available(iOS 26.0, *)` 双栈 | **部署目标升 26.0，删除双栈守卫**（DockKit 下限 17 仍满足） | 前提已保证 26+；无双栈则无 LegacyTransport，iPhone 端传输代码减半 |
| 3 | Wi-Fi Aware 定位"第三条可选通道"，Bonjour 保持主路径 | **Wi-Fi Aware 升首选，Bonjour 降备用**，扫码/手工 IP 永久兜底 | 用户明确指示；全 26+ 前提下 WA 的无路由器/免授权弹窗/强加密收益全额兑现 |
| 4 | 采集回传独立端口 9103（TLV 化但仍是第二连接） | **并入主 TLV 连接** type 10/11，不新增端口 | TLV 的 type 路由天然支持多业务复用单连接；录制→停止→回传的时序与 15fps 视频流错峰，无队头争用实测依据后再分离也来得及 |
| 5 | Coder 信封枚举"P3 再评估" | 消息映射表**预留 type 2**，P3 做或留 TODO 均记录 | 与原方案一致，仅明确落位 |
| 6 | 端口表：9100（旧）/9102（TLV）/9103（采集） | 收敛为 **9100 单端口**（TLV 服务直接复用 9100 与 `_aimphone._tcp` 服务名，过渡期并存 9102） | 无旧客户端混跑风险，无需长期背着"2"；二维码 payload 不变（`port` 即 TLV 端口），`port2` 字段过渡期内有效 |
| 7 | 路由器恢复时"回 Bonjour 或保持 WA"未定 | **保持 WA 不回落**（已加密且低延迟，通道切换只会引入中断） | 简化编排；实测劣化再议，记 ADR |

## 5. 文件级改动清单

> 所有新文件带 L0 文件头，注释中文（comment-style.md）。

### Mac 端

| 文件 | 改动 |
|---|---|
| `Package.swift` | `swift-tools-version: 6.2`；`platforms: [.macOS(.v26)]` |
| 打包脚本 / xcodegen | **P0 关键**：ScreenAim 包成 .app，Info.plist 声明可发布服务 `_aimphone-wa._tcp`；CLI 降级构建保留（无 WA） |
| `Sources/ScreenAim/FrameServerV2.swift`（新增） | `NetworkListener(on: 9100/9102) { TLV { TCP() } }`；`connection.messages` 分发 type 0/1/10/11；回调面与 FrameServer 对齐（onFrame/onConnect/onControl/onDisconnect/handshakePayload），上层 Calibrator 接线无差别 |
| `Sources/ScreenAim/WifiAwareServer.swift`（新增） | `WACapabilities` 探测；`NetworkListener(for: .wifiAware(...))` 同一 TLV 分发；性能报告定时采样进 CSV |
| `Sources/ScreenAim/CaptureServerV2.swift` | **不再新建**——采集回传并入 FrameServerV2 的 type 10/11，`IngestSession` 落盘逻辑抽公共函数复用 |
| `Sources/ScreenAim/main.swift` | `--serve` 起 V2 服务（+过渡期旧服务）+ WA listener（能力不满足打印降级日志）；二维码 JSON 加 `port2`（过渡期）；悬浮层 pill 显示链路来源（wa/bonjour/manual） |
| 拆除期 | V2 回归通过后删 `FrameServer`/`CaptureServer` 手工分帧代码与旧端口 |

### iPhone 端（XcodeGen）

| 文件 | 改动 |
|---|---|
| `ios/project.yml` | 部署目标升 26.0；`NSBonjourServices` 加 `"_aimphone2._tcp."`；Info.plist 声明可订阅服务 `_aimphone-wa._tcp` |
| `ios/AimPhone/TLVTransport.swift`（新增） | `NetworkConnection` 封装：连接/看门狗重试（5s×6，`withThrowingTaskGroup` 超时竞争，仅 Bonjour/IP 路径需要）、`send(jpeg:)`/`sendControl(_:)`/采集上传、控制消息接收循环、断开前 `mouseUp all` + `disconnect` 兜底 |
| `ios/AimPhone/WifiAwareTransport.swift`（新增） | `WAPairedDevice.allDevices` 订阅配对表；`NetworkBrowser(.wifiAware)` → `NetworkConnection`；与 TLVTransport 共用消息收发核心（组合，非继承） |
| `ios/AimPhone/PairingView.swift`（新增） | `DevicePicker` SwiftUI 封装，入口放设置/连接面板 |
| `ios/AimPhone/CameraStreamer.swift` | 连接策略编排：已配对且 WA 可用 → ①；否则 Bonjour ②；手动 IP/扫码 ③；`suppressAutoConnect` 语义对三通道一致；**旧 NWConnection 手工分帧实现拆除期删除** |
| `ios/AimPhone/CaptureRecorder.swift` | 仅上传段改走 TLV type 10/11，录制逻辑不动 |

### 文档（同提交更新，docs/README.md 维护约定）

- `docs/protocol.md`：新增 §11「TLV 消息通道（iOS 26/macOS 26+）」与 §12「Wi-Fi Aware
  通道（配对/发现/传输）」；§1/§2/§10 在拆除期标注"已移除"并指向 §11；端口表收敛。
- `docs/decisions.md`：ADR-011（前提变更引发的四项决策：拆旧链路、升部署目标、
  WA 升首选、单连接复用）。
- `docs/modules.md`：FrameServerV2/WifiAwareServer/TLVTransport/WifiAwareTransport 条目。
- 原两方案文档头部标注"已并入本文"。

## 6. 阶段计划

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 可行性尖刺**（0.5d，**不过则 WA 部分终止**） | ① 真机 iOS ≥26 且 iPhone 12+ 复核记录；② `swift build` 在 tools 6.2 + v26 平台通过（仅改清单）；③ Mac 包壳 .app 的 `WACapabilities.supportedFeatures` 实测 + Info.plist 服务声明确认可读 | ①②不过则整体终止；③不过则 WA 通道终止、TLV + Bonjour 主路径照常推进，方案降级记录 ADR |
| **P1 TLV 单连接传输**（1.5d） | FrameServerV2（含 type 10/11 采集并入）+ TLVTransport + 双服务过渡并起 + 二维码 port2 | 15fps 推流 + 鼠标事件 + calib 下发 + 采集回传全通；`scenes/localaim_*.csv` 新会话 `src=tlv`；`--replay` 回放像素级一致；断连兜底（mouseUp all）验证 |
| **P2 Wi-Fi Aware 通道**（1d，依赖 P1） | PairingView/DevicePicker + WifiAwareServer/Transport + 三通道优先级编排 + realtime 模式 + 性能报告采样 | 配对一次后杀 App 重开靠近自动连上；拔路由器全流程可用；延迟/抖动 CSV 对比 Bonjour 不劣化；配对码 UX 成本实测记录进 ADR |
| **P3 收敛与文档**（0.5d） | 拆旧链路（9100 手工分帧 + iPhone 旧实现）；Coder type 2 评估；protocol.md §11/§12 + ADR + modules.md | 拆除后全量回归绿；docs/README.md 检查表全绿；本方案状态改"已实施" |

**明确不做**（守住范围）：QUIC 栈（api-details §7 已评估，局域网小包握手开销大于收益）、
视频编码替换、AccessorySetupKit、跨平台 NAN 互通、UDP 结果通道（属
positioning-optimization-plan.md Phase 3，届时走 NetworkConnection UDP）。

## 7. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| Mac 包壳 .app 无法发布 WA 服务（CLI 无 Info.plist 硬伤） | WA 通道不成立 | P0 尖刺先验证；不过则降级为 TLV+Bonjour 主路径，WA 归档"待生态成熟" |
| 初代 API 稳定性（发现失败/断连，论坛已有互通性报告） | 演示现场翻车 | 三通道编排 + 永久保留扫码兜底；现场演示前真机矩阵实测 |
| 拆旧链路后回滚需求 | 无退路 | 拆除单独一个 commit；旧链路在 git 历史中可完整恢复 |
| 采集回传与视频流单连接争用（推测无，未实测） | 回传期间视频卡顿 | P1 验收含"回传同时推流"场景；劣化则退回独立端口（TLV 栈不变，改动极小） |
| 看门狗语义在 WA 主路径下被遗忘 | 授权弹窗期卡死重现（仅 Bonjour 路径存在） | TLVTransport 复刻 5s×6 重试，Bonjour/IP 路径真机弹窗实测 |
| realtime 模式功耗 | 长时间发热掉电 | 性能报告采样监控；闲置回 bulk 或断开（API 允许时） |
| 与基础设施 Wi-Fi 并发射频竞争 | 延迟抖动 | P2 性能报告对比实测；劣化则调整优先级编排 |

## 8. 激活提示词

把下面这段原样发给 Agent 即可启动实施：

```
激活传输层整体迁移方案：按 /Users/jup33q/Documents/kimi/screen_aim/docs/transport-26-plan.md
执行（该文已合并取代 tlv-migration-plan.md 与 wifi-aware-pairing-plan.md），
先调用 skills 里的 network-framework-tlv 与 wifi-aware-pairing 技能，
从 P0 可行性尖刺开始——先实测 Mac 包壳 App 的 WACapabilities 与 Info.plist 服务声明，
WA 不过则降级为 TLV+Bonjour 主路径继续；逐阶段实施，严格遵守 docs/comment-style.md
注释规范与 docs/README.md 文档同步约定；旧链路拆除只在 P3 且单独成 commit。
```
