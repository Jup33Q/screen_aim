---
name: network-framework-tlv
description: Apple Network.framework iOS 26/macOS 26 新一代结构化并发 API（NetworkConnection / NetworkListener / NetworkBrowser）与内置 TLV 消息帧（Type-Length-Value framer）、Coder 协议（Codable 直接收发）的实战指南。当用户要把手工字节流帧协议（如 [4字节长度][payload]、JSONSerialization 控制帧）迁移到框架内置 TLV 消息流、在 iPhone 与 Mac 之间做低延迟局域网传输、或提到 NetworkConnection / TLV framer / Coder(using: .json) / NWProtocolFramer 时使用。覆盖 API 用法、线上格式、NWConnection→NetworkConnection 迁移映射、版本门槛（iOS/macOS 26）与新旧客户端兼容策略。
---

# Network.framework TLV 消息流（iOS 26 / macOS 26+）

iOS 26 / macOS 26（WWDC25 Session 250）为 Network.framework 引入结构化并发 API 三件套——
`NetworkConnection` / `NetworkListener` / `NetworkBrowser`，以及两个消息层原语：

- **TLV framer**：内置 Type-Length-Value 分帧器。线上格式 `[type: UInt32][length: UInt32][value]`（网络字节序，8 字节头），框架自动拼包/拆包——**发 3 条消息，对端恰好收 3 条**，手工 `readHeader/readBody` 状态机整体作废。
- **Coder 协议**：`Coder(MyType.self, using: .json)` 声明进协议栈后，连接直接收发 Codable 实例，JSON 编解码由框架托管。

详细 API 与代码模板见 [references/api-details.md](references/api-details.md)。

## 何时用 / 不用

| 场景 | 选择 |
|---|---|
| 同一连接上跑多种消息（视频帧 + 控制 JSON + 心跳） | **TLV**，type 字段即消息路由，替代"长度字最高位当标志位"这类手工位打包 |
| 消息全是 JSON 控制信令 | **Coder + Codable enum**，类型安全、消灭 `JSONSerialization` |
| 大二进制与 JSON 混合（如 JPEG 帧 + 元数据） | **TLV**（视频 type=原始字节，控制 type=JSON），不要用 Coder——Codable JSON 会把 Data 编成 Base64，体积 +33% |
| UDP 小包通道（坐标上报、latest-wins） | NWConnection UDP（`receiveMessage`），TLV 是流分帧器，UDP 本身已有消息边界 |
| 部署目标 < iOS 26 / macOS 26 | 不可用，留在 `NWConnection` 手工分帧；两端 API 可共存、增量迁移 |

## 硬约束（踩坑清单）

1. **版本门槛**：`NetworkConnection` / `TLV` / `Coder` 仅 iOS 26 / macOS 26+。iOS 端必须
   `if #available(iOS 26.0, *)` 双栈；Mac SwiftPM CLI 需 `swift-tools-version: 6.2+` 且
   `platforms: [.macOS(.v26)]`（Swift 6.3 工具链已验证可用）。
2. **线上格式不向后兼容**：内置 TLV 头是 8 字节（type+length），与既有 `[4B 长度]` 手工帧**无法在同一端口混跑**。新旧客户端共存 = 开第二个监听端口 + 第二个 Bonjour 服务名（如 `_aimphone2._tcp`），不要试图在同一连接上协商切换。
3. **声明式协议栈从外层往内写**：`TLV { TLS() }` = TLV 在 TLS 之上；局域网明文场景写 `TLV { TCP() }`。
4. **不要手工实现 `NWProtocolFramer`**（iOS 12+ 时代的自定义分帧器，handleInput/handleOutput 约 100 行样板代码）——iOS 26 起内置 TLV 已覆盖其典型用途；只有线上格式必须兼容非 Apple 端（嵌入式/Linux 对端）时才回到 NWProtocolFramer 或保留手工分帧。
5. **流控**：`try await connection.send(data)` 的挂起即背压（等价旧 API 的 `contentProcessed` 回调），不要在循环里无 await 地灌数据；视频帧这类高频发送天然获得节流。
6. **旧 API 不要混用**：同一进程里 NWConnection 与 NetworkConnection 可并存，但**同一条逻辑链路上只选一套**，状态回调（`stateUpdateHandler`）与 `for await state in connection.states` 不要同时挂。
7. **生命周期**：NetworkConnection 不需要 `[weak self]`（Task 取消即连接取消）；离开作用域前显式 `cancel()` 或让 Task 结构化管理，避免僵尸连接。

## 迁移映射（NWConnection → NetworkConnection）

| 旧（iOS 12–25） | 新（iOS 26+） |
|---|---|
| `stateUpdateHandler = { ... }` | `for await state in connection.states { }` |
| `send(content:completion:)` | `try await connection.send(_:)` 或 `send(_:type:)`（TLV） |
| `receive(min:max:completion:)` 手工拼帧 | TLV 下 `try await connection.receive()` → `(content, metadata)`，`metadata.type` 路由 |
| `[4B 大端长度][payload]` + 高位标志 | TLV 头自动分帧，type 字段替代位标志 |
| `JSONSerialization` 双向手写 | `Coder(AimMessage.self, using: .json)` + `connection.messages` 异步序列 |
| `NWListener(using:on:)` + `newConnectionHandler` | `try await NetworkListener { TLV { TCP() } }.run { conn in ... }`（每个入站连接一个子任务） |
| `NWBrowser(for: .bonjour(...))` | `NetworkBrowser`（同支持 Bonjour，另支持 Wi-Fi Aware） |
| 每个回调 `[weak self]` | 不需要 |

## 最小骨架

```swift
import Network

// 服务端：每连接一个子任务，消息即收即得
try await NetworkListener(on: .init(integerLiteral: 9102)) {
    TLV { TCP() }
}.run { connection in
    for try await (data, metadata) in connection.messages {
        switch metadata.type {
        case 0: handleVideo(data)          // JPEG 帧
        case 1: handleControlJSON(data)    // 控制消息
        default: break                     // 未知 type 忽略，向后兼容
        }
    }
}

// 客户端：发送带类型消息
let conn = NetworkConnection(to: .hostPort(host: host, port: 9102)) { TLV { TCP() } }
try await conn.send(jpegData, type: 0)
try await conn.send(jsonData, type: 1)
```

## 验证要点

- 真机 + 真实 Wi-Fi 验证（模拟器不覆盖本地网络授权弹窗路径）；
- 用 Network Link Conditioner 加 100ms/3% 丢包验证消息边界不错乱；
- 新旧两端交叉互测：新 Mac + 旧 iPhone（走 legacy 服务）、旧 Mac + 新 iPhone（回退）、新 + 新（TLV）。
