---
name: wifi-aware-pairing
description: Apple Wi-Fi Aware（NAN，邻域感知网络）在 iOS 26 / macOS 26 的实战指南。当用户要替代扫码/IP 输入式设备配对、实现无路由器的 iPhone↔Mac 直连、零配置局域网发现、或提到 Wi-Fi Aware / WiFiAware / NAN / DeviceDiscoveryUI / AccessorySetupKit / DevicePicker / WAPairedDevice 时使用。覆盖能力判定（WACapabilities）、系统配对流程、Network.framework 集成（NetworkListener/NetworkBrowser 的 .wifiAware 描述符）、性能模式（realtime/bulk + 性能报告）、Info.plist 服务声明要求与平台限制（Mac Catalyst 不支持、配对 UI 需 App 上下文）。
---

# Wi-Fi Aware 配对与直连（iOS 26 / macOS 26+）

Wi-Fi Aware（Wi-Fi Alliance NAN 标准）是**无路由器、无接入点**的设备到设备直连：发现、配对、
连接全部系统托管，数据通道强制认证+加密，与常规 Wi-Fi 并发工作。Android 8+ 已支持多年，
Apple 在 iOS/iPadOS 26 与 macOS 26.0 加入（WWDC25 Session 228）。

详细 API 与代码模板见 [references/api-details.md](references/api-details.md)。

## 它能替代什么

| 传统做法 | Wi-Fi Aware 对应物 |
|---|---|
| 扫码获取 IP/端口、手工输地址 | 系统级配对（DeviceDiscoveryUI / AccessorySetupKit），一次配对持久有效 |
| Bonjour/mDNS 发现（要求同局域网） | NAN 服务发现（**不需要任何网络**，靠近即可发现） |
| 基础设施 Wi-Fi 传输（需路由器、受"本地网络权限"弹窗折磨） | 直连数据通道（datapath），强制加密，不触发本地网络授权 |
| 自建配对码/信任机制 | 系统 pairing code 流程 + `WAPairedDevice` 配对设备注册表 |

## 硬约束（踩坑清单）

1. **平台与硬件**：iOS/iPadOS 26+ 且 iPhone 12 及以上、近三代 iPad；macOS 26.0+（原生 App。
   **Mac Catalyst 不可 import WiFiAware**——论坛 2026-05 确认）。运行前必须查
   `WACapabilities.supportedFeatures.contains(.wifiAware)`。
2. **配对是强制的**：Wi-Fi Aware API 只能连接**已配对**设备。配对走系统 UI——
   `DeviceDiscoveryUI`（App↔App，支持 Apple 与第三方设备）或 `AccessorySetupKit`
   （App↔配件）。配对过程系统会提示输入 pairing code——**配对码环节本身也是一次用户交互**，
   并不比扫码省步骤；省的是"之后永远不用再配"。
3. **Info.plist 服务声明**：可发布/可订阅服务必须声明在 Info.plist
   （`WAPublishableService.allServices["_file-service._tcp"]!` 这样取值）。
   **对 macOS 命令行工具是硬伤**——SwiftPM 可执行文件没有 Info.plist，Mac 做发布方需要
   先包成 .app bundle。
4. **角色模型**：一端 publisher（listener），一端 subscriber（browser）；可双角色。
   配对后重连由系统托管，靠近即连。
5. **性能模式二选一**：`.bulk`（省电、高延迟）/ `.realtime`（低延迟、费电）——
   实时瞄准/投屏类必须 `.realtime` + `.serviceClass(.interactiveVideo)`，并接受续航代价；
   每连接可读性能报告（信号强度/吞吐/延迟）：
   `try await connection.currentPath?.wifiAware?.performance`。
6. **加密不可关**：Apple 实现强制 datapath 加密（ESP32 社区已踩到——第三方 NAN 设备
   默认不加密的玩法在 Apple 侧走不通）。
7. **初代 API 成熟度**：iOS 26.0 时代论坛已有多个互通性/发现失败报告（ESP32 互通、
   蜂窝机型 P2P 发现异常等），上线前必须真机矩阵实测，并保留旧发现链路做回退。
8. **配对 UI 需要 App 上下文**：`DevicePicker`/`DevicePairingView` 是 SwiftUI 视图，
   由 iPhone 端承载最自然；Mac 端只做 listener/publisher 逻辑角色。

## 与 Network.framework 的集成形态

Wi-Fi Aware 只负责**发现+配对+建立直连**；连上之后就是普通的 Network.framework 连接，
可以叠任意协议栈——包括 iOS 26 的 TLV framer（见 network-framework-tlv skill）：

```swift
import WiFiAware
import Network

// Publisher（如 Mac）：监听已配对设备
let listener = try NetworkListener(
    for: .wifiAware(.connecting(to: .aimService, from: .matching(deviceFilter))),
    using: .parameters { TLV { TLS() } }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.interactiveVideo))
try await listener.run { connection in /* 每入站连接一个子任务 */ }

// Subscriber（如 iPhone）：浏览已配对设备并连接
let browser = NetworkBrowser(
    for: .wifiAware(.connecting(to: .matching(deviceFilter), from: .aimService)))
let endpoint = try await browser.run { endpoints in
    if let ep = endpoints.first { return .finish(ep) } else { return .continue }
}
let connection = NetworkConnection(to: endpoint,
    using: .parameters { TLV { TLS() } }
        .wifiAware { $0.performanceMode = .realtime }
        .serviceClass(.interactiveVideo))
```

## 选型对照（本项目语境：iPhone ↔ Mac 瞄准链路）

| 路径 | 需要路由器 | 需要配对动作 | 系统版本 | 适用 |
|---|---|---|---|---|
| Bonjour + 局域网 TCP（现状主路径） | 是 | 无（自动发现） | 任意 | 日常开发、家/办公室 |
| 二维码/手工 IP（现状兜底） | 是 | 每次扫一次 | 任意 | Bonjour 失效时 |
| **Wi-Fi Aware** | **否** | **一次性系统配对** | 双端 26+，iPhone 12+ | 无路由器演示场地、不可信网络、想消灭授权弹窗 |
| includePeerToPeer（AWDL） | 否 | 无 | 任意 | 已知 50–100ms 周期延迟尖峰，本项目不推荐默认开 |

**结论性建议**：Wi-Fi Aware 定位为**第三条可选通道**（无路由器场景的首选），
不是对现有 Bonjour 主路径的替换；二维码兜底永远保留。
