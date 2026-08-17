# Network.framework TLV / Coder API 明细（iOS 26 / macOS 26+）

来源：WWDC25 Session 250 "Use structured concurrency with Network framework"（Apple Developer，
2025-06）；Apple Developer Forums thread 807135（2026-02，QUIC stream + TLV 实战）。

## 1. 声明式协议栈

`NetworkConnection` / `NetworkListener` 的初始化器接受一个结果构建器（result builder），
**外层协议包内层**，从左到右 = 从应用层到传输层：

```swift
import Network

// 明文局域网：TLV 在 TCP 之上
NetworkConnection(to: .hostPort(host: "192.168.1.100", port: 9102)) {
    TLV { TCP() }
}

// 需要加密：TLV 在 TLS 之上
NetworkConnection(to: .hostPort(host: "example.com", port: 1029)) {
    TLV { TLS() }
}

// 自定义传输参数：IP 层选项
NetworkConnection(to: .hostPort(host: "example.com", port: 1029)) {
    TLS {
        TCP {
            IP().fragmentationEnabled(false)
        }
    }
}

// 连接级参数（低数据模式/计费路径/多径）
NetworkConnection(to: endpoint,
                  using: .parameters { TLS() }
                             .constrainedPathsProhibited(true))
```

端点类型：`.hostPort(host:port:)`、`.service(name:type:domain:interface:)`（Bonjour）、
`.unix(path:)`。

## 2. TLV framer

### 线上格式

```
┌──────────────┬────────────────┬──────────────────┐
│ type: UInt32 │ length: UInt32 │ value: [UInt8]   │
│ 4 字节        │ 4 字节          │ length 字节       │
└──────────────┴────────────────┴──────────────────┘
```

- 每条消息固定 8 字节头，type 由发送方指定、接收方经 `metadata.type` 读回；
- length 由框架填/验，**应用层不再触碰长度字**；
- 流协议（TCP/TLS）上保持消息边界：send 几次，receive 就回调几次，无粘包/半包状态机。

### 发送 / 接收

```swift
// 发送：data + 类型号（Int/UInt32 兼容的整数）
try await connection.send(characterData, type: GameMessage.selectedCharacter.rawValue)

// 接收：一条完整消息 + 元数据
let (incomingData, metadata) = try await connection.receive()
switch GameMessage(rawValue: metadata.type) { ... }

// 异步序列形态（配合 NetworkListener 的 run 闭包最顺手）
for try await (data, metadata) in connection.messages { ... }
```

`try await send` 挂起 = 数据已被协议栈消费，天然背压（等价 NWConnection 的
`contentProcessed` 完成回调），循环发送无需额外节流。

### 未知 type 的处理约定

接收方 `switch` 必须带 `default: break`（或记录日志）——这是 TLV 通道的向后兼容机制：
新版发送方新增的 type 不应使旧版接收方断连。

## 3. Coder 协议（Codable 直发直收）

```swift
enum GameMessage: Codable {
    case selectedCharacter(String)
    case move(row: Int, column: Int)
}

// 声明进栈：Coder(消息根类型, using: 编码器) { 下层协议 }
let connection = NetworkConnection(to: .hostPort(host: "www.example.com", port: 1029)) {
    Coder(GameMessage.self, using: .json) {
        TLS()
    }
}

// 发：直接发枚举实例
try await connection.send(GameMessage.selectedCharacter("🐨"))

// 收：直接得枚举实例
let gameMessage = try await connection.receive().content

// Listener 形态
try await NetworkListener {
    Coder(GameMessage.self, using: .json) { TLS() }
}.run { connection in
    for try await (gameMessage, _) in connection.messages {
        // 处理 GameMessage
    }
}
```

注意：
- `using: .json` 内部即 JSONEncoder/JSONDecoder——**Data 字段会 Base64**，大二进制负载
  （JPEG/PNG 帧）不要走 Coder，走 TLV 的原始字节消息；
- 双向消息集合不同向时，定义一个覆盖全集的 Codable 信封枚举（各 case 带关联值），
  两端共用同一类型声明（放共享 target，如本项目的 `ScreenAimCore`）；
- Coder 本质上构建在 TLV 之上（每条 Codable 消息一条 TLV 记录），可视为"TLV + JSON 编解码
  托管"的语法糖。

## 4. 字节流收发（无分帧器时的原语）

```swift
// 定长读：恰好 n 字节才返回
let header = try await connection.receive(exactly: 98).content

// 网络字节序定长类型直读（大端 UInt32 长度字等）
let len32 = try await connection.receive(as: UInt32.self).content

// 变长读：循环直到凑够
var remaining = Int(exactly: len32)!
while remaining > 0 {
    let chunk = try await connection.receive(atLeast: 1, atMost: remaining).content
    remaining -= chunk.count
}
```

## 5. 状态与生命周期

```swift
// 状态机：preparing → ready ⇄ waiting → failed / cancelled
for await state in connection.states {
    // .ready 前 send/receive 会挂起等待连接建立（首次 send 自动触发连接）
}
```

- `send`/`receive` 在连接未建立时会先触发建立并挂起——"首包即连接"；
- 错误以 `throws` 自然传播，Task 取消即连接取消，无需 `[weak self]`；
- `.waiting`（如本地网络授权弹窗期）仍会挂起——**看门狗逻辑（超时取消重试）在新 API 下
  依然需要自行实现**（`withThrowingTaskGroup` 竞争 send 与超时 Task，或保留旧连接路径的
  5s 看门狗策略）。

## 6. NetworkListener / NetworkBrowser

```swift
// 监听：run 闭包每入站连接生成一个结构化子任务
try await NetworkListener(on: .init(integerLiteral: 9102)) {
    TLV { TCP() }
}.run { connection in
    for try await (data, metadata) in connection.messages { ... }
}

// 浏览（Bonjour / Wi-Fi Aware）
import WiFiAware
let endpoint = try await NetworkBrowser(
    for: .wifiAware(.connecting(to: .allPairedDevices, from: .ticTacToeService))
).run { endpoints in .finish(endpoints.first!) }
```

Bonjour 服务发布在新 API 下同样支持（listener 初始化携带 service 描述）；现有
`_aimphone._tcp` 发布/浏览逻辑若不动 NWConnection 路径可原样保留。

## 7. QUIC 备注

iOS 26 的 Network.framework 暴露 QUIC 协议栈（`QUIC()` builder，多流复用无队头阻塞）；
QUIC stream 外层可再包 TLV 使流变消息（Forums 807135 的实战形态）。对 20Hz 小包/局域网
场景握手与加密开销大于收益，本项目不采用；仅记录为后续可选路径。
