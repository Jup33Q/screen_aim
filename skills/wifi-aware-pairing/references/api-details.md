# Wi-Fi Aware API 明细（iOS 26 / macOS 26+）

来源：WWDC25 Session 228 "Supercharge device connectivity with Wi-Fi Aware"（Apple Developer，
2025-06）；WWDC25 Session 250（NetworkBrowser 的 .wifiAware 用法）；Apple Developer Forums
（791628 配对强制性、827887 macOS 支持、826xxx Catalyst 不可导入、ESPressif ESP-IDF #16743
加密强制/互通性问题）。

## 1. 能力判定与服务声明

```swift
import WiFiAware

// 硬件/系统是否支持（运行前必查）
guard WACapabilities.supportedFeatures.contains(.wifiAware) else { return }

// 服务必须先声明进 Info.plist，再以静态属性方式取用：
// 可发布服务（本机做 publisher/listener 时广播出去的服务）
extension WAPublishableService {
    public static var aimService: WAPublishableService {
        allServices["_aimphone-wa._tcp"]!
    }
}

// 可订阅服务（本机做 subscriber/browser 时去发现的服务）
extension WASubscribableService {
    public static var aimService: WASubscribableService {
        allServices["_aimphone-wa._tcp"]!
    }
}
```

支持硬件（Apple 官方清单，2025-06）：iPhone 12 及后续；iPad 10 代+、iPad mini 6 代+、
iPad Air 4 代+、iPad Pro 11" 3 代+ / 12.9" 5 代+；Mac 需 macOS 26.0+（原生进程，
**Mac Catalyst 不支持**）。

## 2. 配对（一次性，系统托管）

### 方式 A：DeviceDiscoveryUI（App ↔ App，本项目适用）

```swift
import DeviceDiscoveryUI
import WiFiAware
import SwiftUI

// Listener/Publisher 侧（如 Mac 对应的配对视图；UI 通常由 iPhone 端发起）
DevicePairingView(.wifiAware(.connecting(to: .aimService, from: .selected([])))) {
    // 系统 UI 弹出前的占位视图
} fallback: {
    // 出错时的兜底视图
}

// Browser/Subscriber 侧（如 iPhone）
DevicePicker(.wifiAware(.connecting(to: .selected([]), from: .aimService))) { endpoint in
    // 拿到已配对设备的网络端点，可直接建 NetworkConnection
} label: {
    // 占位视图
} fallback: {
    // 兜底视图
}
```

### 方式 B：AccessorySetupKit（App ↔ 配件，本项目不适用，记录备查）

```swift
import AccessorySetupKit

let descriptor = ASDiscoveryDescriptor()
descriptor.wifiAwareServiceName = "_drone-service._udp"
descriptor.wifiAwareModelNameMatch = .init(string: "Example Model")
let item = ASPickerDisplayItem(name: "My Drone", productImage: img, descriptor: descriptor)
let session = ASAccessorySession()
session.activate(on: queue) { event in
    // .accessoryAdded 时可用 ASAccessoryWiFiAwarePairedDeviceID 查 WAPairedDevice
}
session.showPicker(for: [item]) { error in }
```

### 配对设备注册表

```swift
import WiFiAware

// 属性：pairingInfo?.pairingName / vendorName / modelName
let device: WAPairedDevice = ...

// 谓词过滤 + 快照流（设备增删变都会推新快照）
let filter = #Predicate<WAPairedDevice> {
    $0.pairingInfo?.vendorName.starts(with: "Example Inc") ?? false
}
for try await devices in WAPairedDevice.allDevices(matching: filter) { ... }
```

**注意**：论坛 791628 确认——配对是强制的，Wi-Fi Aware API 只对已配对设备可用；
配对流程中系统会提示输入 pairing code（2025-11 论坛帖确认两个框架都会提示）。

## 3. 连接（Network.framework 集成）

```swift
import WiFiAware
import Network

// Publisher：对已配对设备建 listener（run 期间占用射频资源）
let deviceFilter = #Predicate<WAPairedDevice> { $0.name?.starts(with: "My Mac") ?? false }
let listener = try NetworkListener(
    for: .wifiAware(.connecting(to: .aimService, from: .matching(deviceFilter))),
    using: .parameters { TLS() })
    .onStateUpdate { listener, state in /* ready/failed/waiting */ }

try await listener.run { connection in
    connection.onStateUpdate { connection, state in }
    // 连接上之后是普通 NetworkConnection：send/receive/messages 照常
}

// Subscriber：浏览 → 选端点 → 建连
let browser = NetworkBrowser(
    for: .wifiAware(.connecting(to: .matching(deviceFilter), from: .aimService)))
    .onStateUpdate { browser, state in }
let endpoint = try await browser.run { waEndpoints in
    if let ep = waEndpoints.first { return .finish(ep) } else { return .continue }
}
let connection = NetworkConnection(to: endpoint, using: .parameters { TLS() })
```

协议栈可自由组合：`TLV { TLS() }`、`Coder(Msg.self, using: .json) { TLS() }` 等
（见 network-framework-tlv skill）。

## 4. 性能调优

```swift
// 两端分别配置：realtime 模式 + 交互视频服务等级
let params = NWParametersBuilder.parameters { TLS() }
    .wifiAware { $0.performanceMode = .realtime }   // 默认 .bulk（省电高延迟）
    .serviceClass(.interactiveVideo)

// 每连接按需读性能报告：信号强度 / 吞吐 / 延迟
let report = try await connection.currentPath?.wifiAware?.performance
```

- `.bulk`：节能优先，延迟高——文件传输用；
- `.realtime`：低延迟，功耗高——瞄准/投屏/远控用，需告知用户续航代价；
- Apple 官方建议：在拥挤 Wi-Fi 环境实测，并结合 TCP 层的连接反馈调 ABR。

## 5. 已知风险与社区实测（截至 2026-08）

| 问题 | 出处 | 对本项目的意义 |
|---|---|---|
| ESP32（ESP-IDF nan_publisher）与 iOS 26 配对失败，"Invalid time bitmap in Availability" | ESP-IDF #16743 | 第三方 NAN 设备互通性未稳；本项目是 Apple↔Apple，风险较低但仍需真机验证 |
| Apple 实现强制 datapath 加密，无 API 关闭 | 同上 | 安全是优点；与非 Apple 设备互通需对方也加密 |
| WiFiAware 在 Mac Catalyst 不可 import | Forums 826xxx（2026-05/06） | Mac 侧必须原生（SwiftPM 可执行文件 + app 包装，或 Xcode 原生 target） |
| 配对流程 pairing code 提示是否可跳过不明确 | Forums（2025-11） | 配对 UX 成本需在 PoC 实测，若与扫码相当则收益重估 |
| iOS 26.0 蜂窝机型 P2P 发现异常 | Forums 808917（Apple P2P Wi-Fi 语境，非 Wi-Fi Aware，但同射频子系统） | 初代稳定性：保留 Bonjour 回退链路是硬要求 |
