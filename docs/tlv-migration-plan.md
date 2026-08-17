# TLV 消息流迁移实施方案（Network.framework，iOS 26 / macOS 26+）

> 状态：**已并入 [transport-26-plan.md](transport-26-plan.md)**（2026-08-17 按"全部署机
> iOS 26/macOS 26+"前提复审合并，双服务永久并行、双栈守卫等保守设计已在该文修订）。
> 本文保留为调研背景，实施以 transport-26-plan.md 为准。
> 前置阅读：[protocol.md](protocol.md)（现行线上格式）、
> [skills/network-framework-tlv](../skills/network-framework-tlv/SKILL.md)（API 指南）、
> [comment-style.md](comment-style.md)（注释规范，所有新文件带 L0 文件头）。

## 1. 目标与动机

用 Network.framework 内置 TLV framer（+ 可选 Coder 协议）替换全部手工分帧：

| 现状（手工） | 目标（框架托管） |
|---|---|
| `[4B 大端长度][JPEG]`，长度字最高位当"控制帧"标志位 | TLV `[type:u32][len:u32][value]`，type 路由消息 |
| Mac 端 `FrameServer.readHeader/readBody/readBody0` 三段状态机 | `for try await (data, metadata) in connection.messages` |
| iPhone 端 `receiveControl` 双段 receive 嵌套 | 同上 |
| `JSONSerialization` 手写编解码（`[String: Any]` 无类型） | 可选：`Coder(AimMessage.self, using: .json)` Codable 信封枚举 |
| 采集回传 `[4B jsonLen][json][4B binLen][bin]` + `readExact` 链 | TLV 消息（kind 进 type 字段，bin 为 value 或复合 payload） |
| 回调地狱 + 每回调 `[weak self]` | async/await 结构化并发，Task 取消即连接取消 |

**不改的部分**（与传输升级正交，维持 protocol.md §2/§3 现状）：Bonjour 发现语义、二维码配对 payload、
calib 下发时机、鼠标事件语义、CSV 日志格式。视频编解码（JPEG→HEVC）不在本方案范围。

## 2. 硬约束（调研确认）

- **版本门槛**：`NetworkConnection`/`TLV`/`Coder` 仅 iOS 26 / macOS 26+。
  - Mac 端已满足：macOS 26.6.1 + Swift 6.3.3（`swift-tools-version` 需升到 6.2+ 才有 `.macOS(.v26)`）。
  - iPhone 端部署目标 17.0（DockKit 需求），**必须 `if #available(iOS 26.0, *)` 双栈**，
    真机 iOS 版本实施前需确认（§6 P0）。
- **线上格式不兼容**：TLV 8 字节头 ≠ 现行 4 字节头，同一端口无法混跑 → 双服务并行（§3）。
- **TLV 是流分帧器**：Phase 3 规划的 UDP 结果通道（positioning-optimization-plan.md §7.7）
  不需要 TLV（UDP 自带消息边界），本方案只覆盖 TCP 链路。
- **大二进制不走 Coder**：Codable JSON 的 Data 是 Base64（+33% 体积）。视频帧走 TLV 原始字节消息。

## 3. 目标拓扑：双服务并行（向后兼容）

```
Mac                                          iPhone
┌─ NWListener 9100  _aimphone._tcp  (旧手工帧) ◀──── iOS <26 客户端（现状代码，冻结不动）
│
└─ NetworkListener 9102 _aimphone2._tcp (TLV)  ◀──── iOS 26+ 客户端（新链路）
      type 0 = 视频帧 JPEG（iPhone→Mac）
      type 1 = 控制 JSON（双向：calib/pairingQR/captureStart↓，localAim/mouse*/disconnect↑）
      9103 = 采集回传（TLV 化，kind→type）
```

- iPhone 双栈策略：`if #available(iOS 26.0, *)` 优先浏览 `_aimphone2._tcp`，
  未发现（旧 Mac）时回退 `_aimphone._tcp` 旧链路；Bonjour 自动发现语义不变。
- 旧 iPhone 永远只看见 9100 服务，行为与今天完全一致——满足项目"只加不删"兼容文化
  （protocol.md §6/§7 各向后兼容条款）。
- 二维码 payload 不变（`{"host","port"}` 仍指 9100）；Mac 端二维码 JSON 增加可选字段
  `"port2":9102`，新 iPhone 扫码后优先连 TLV 端口，旧 iPhone 忽略未知字段。

## 4. 消息映射表（现行 → TLV type）

| 现行消息 | 方向 | TLV type | value |
|---|---|---|---|
| 视频帧 `[len][JPEG]` | ↑ | 0 | JPEG 原始字节 |
| calib（§6） | ↓ | 1 | JSON（格式不变） |
| pairingQR（§6） | ↓ | 1 | 同上 |
| captureStart/Stop（§10） | ↓ | 1 | 同上 |
| togglePairingQR / localAim / disconnect（§7） | ↑ | 1 | 同上 |
| mouseDown/Up/Click/Scroll（§8） | ↑ | 1 | 同上 |
| 采集记录 session/end（§10） | ↑ | 10 | JSON |
| 采集记录 frame（§10） | ↑ | 11 | `[4B jsonLen][json][PNG]` 复合（一次传递，免去 readExact 链） |

type 1 暂留 JSON 是为首版最小 diff；P3 阶段再评估是否升级 `Coder(AimMessage.self)` 信封枚举
（届时 type 2 = Coder 消息，type 1 保留兼容）。

## 5. 文件级改动清单

> 行号锚点基于 2026-08-17 工作区；以符号名为准。所有注释中文、新文件带 L0 文件头。

### Mac 端（SwiftPM）

| 文件 | 改动 |
|---|---|
| `Package.swift` | `swift-tools-version: 6.2`；`platforms: [.macOS(.v26)]` |
| `Sources/ScreenAim/FrameServerV2.swift`（新增） | `NetworkListener(on: 9102) { TLV { TCP() } }`；`run` 闭包内 `connection.messages` 分发 type 0/1；公开与 `FrameServer` 相同的回调面（`onFrame/onConnect/onControl/onDisconnect/handshakePayload`），使上层（Calibrator 接线）两端无差别 |
| `Sources/ScreenAim/CaptureServerV2.swift`（新增） | 端口 9103，TLV 化采集回传；复用 `IngestSession` 落盘逻辑（抽公共函数或参数化目录回调） |
| `Sources/ScreenAim/main.swift` | `--serve` 启动时新旧服务并起；二维码 JSON 加 `port2`；`onListenerFailed` 对两个 listener 分别接；旧 `FrameServer`/`CaptureServer` 一行不改 |
| `Sources/ScreenAimCore/` | 不动（纯算法层，无网络依赖） |

### iPhone 端（XcodeGen）

| 文件 | 改动 |
|---|---|
| `ios/AimPhone/TLVTransport.swift`（新增） | `if #available(iOS 26.0, *)` 内的 `NetworkConnection` 封装：连接/看门狗重试（沿用 5s×6 策略，`withThrowingTaskGroup` 实现超时竞争）、`sendVideo/Data`、`sendControl([String:Any])`、控制消息接收循环、断开前 `mouseUp all` + `disconnect` 兜底（语义对齐现 `disconnect()`） |
| `ios/AimPhone/CameraStreamer.swift` | 抽 `Transport` 协议（`send(jpeg:)` / `sendControl(_:)` / `onControl` / 状态发布）；现有 NWConnection 实现收编为 `LegacyTransport`；`startConnection` 按 OS 版本与 Bonjour 结果选实现；`connectedHostPort` 记录双端口 |
| `ios/AimPhone/CaptureRecorder.swift` | 仅上传段改走 TLV（type 10/11），录制逻辑不动 |
| `ios/project.yml` | `NSBonjourServices` 增加 `"_aimphone2._tcp."`；部署目标维持 17.0 |

### 文档（同提交更新，docs/README.md 维护约定）

- `docs/protocol.md`：新增 §11「TLV 消息通道（v2，iOS 26/macOS 26+）」，§1 头部标注"v1 冻结，
  新功能只进 v2"；
- `docs/decisions.md`：新增 ADR（内置 TLV 替换手工分帧；双服务并行而非同端口协商的理由）；
- `docs/modules.md`：FrameServerV2/TLVTransport 条目。

## 6. 阶段计划

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 环境确认**（0.5h） | 确认真机 iOS ≥26（设置 → 通用 → 关于）；`swift package --version` ≥ 6.2；`swift build` 在 tools 6.2 + v26 平台下通过（不改代码，仅改清单验证工具链） | 构建绿；真机版本记录在 PR 描述 |
| **P1 Mac 端 V2 服务**（0.5d） | FrameServerV2 + 双服务并起 + 二维码 port2；用 `nc`/Swift 脚本模拟 TLV 客户端发自封帧验证分发 | 旧 iPhone 连 9100 全流程回归通过；模拟客户端 type 0/1 收发正确 |
| **P2 iPhone TLVTransport**（1d） | Transport 协议抽取 + TLVTransport 实现 + 双栈选择 | 新链路 15fps 推流 + 鼠标事件 + calib 下发全通；断连兜底（mouseUp all）验证；`scenes/localaim_*.csv` 新会话 `src=tlv` 标记 |
| **P3 采集回传 TLV 化 + Coder 评估**（0.5d） | CaptureServerV2 + 上传段迁移；评估 AimMessage 信封枚举收益，做或留 TODO 均需记录 | `--replay` 回放新采集目录像素级一致 |
| **P4 文档与清理**（0.5d） | protocol.md §11、ADR、modules.md、本方案状态改"已实施" | `docs/README.md` 检查表全绿 |

**明确不做**（守住范围）：UDP 结果通道（走 positioning-optimization-plan.md Phase 3，与本文正交）、
视频编码替换、TLS（局域网明文现状维持，ADR 记录理由）、旧链路删除。

## 7. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 真机 < iOS 26 | TLV 链路永不激活 | 双栈兜底，升级系统后再启用；P0 先确认 |
| 新 API 稳定性（26 初代） | 边界 case crash | P2 全量回归旧链路；TLV 链路异常时自动回退 legacy 并记日志 |
| 看门狗语义丢失 | 授权弹窗期卡死重现 | TLVTransport 必须复刻 5s×6 重试（`TaskGroup` 超时竞争），真机弹窗路径实测 |
| 双服务端口占用混乱 | 僵尸二维码类 bug | `onListenerFailed` 两服务独立接；9102/9103 写进 protocol.md 端口分配表 |
| 内置 TLV 线上格式未文档化到字节级 | 第三方工具无法嗅探调试 | 调试期 Mac 端保留 `--serve` 旧端口 + `nc` 手工注入路径 |

## 8. 激活提示词

把下面这段原样发给 Agent 即可启动实施：

```
激活 TLV 迁移方案：按 /Users/jup33q/Documents/kimi/screen_aim/docs/tlv-migration-plan.md
执行，先调用 skills 里的 network-framework-tlv 技能，从 P0 环境确认开始逐阶段实施，
严格遵守 docs/comment-style.md 注释规范与 docs/README.md 的文档同步约定，
每阶段验收通过后再进下一阶段，P2 完成后真机回归旧链路（9100）确认无损。
```
