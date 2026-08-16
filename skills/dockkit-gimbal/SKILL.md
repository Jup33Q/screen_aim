---
name: dockkit-gimbal
description: iOS DockKit 框架开发与 Insta360 Flow 2 Pro / Flow Pro 等电动云台适配指南。当用户要为相机类 App 接入 DockKit 云台追踪（系统追踪/自定义追踪/取景构图/电机直控/云台动画）、适配 Insta360 Flow 2 Pro 或其他 DockKit 认证支架、处理云台按键事件（快门/变焦/翻转）、排查"云台不追踪"问题，或提到 DockKit / DockAccessory / DockAccessoryManager / 云台追踪 / 电动支架联动 时使用。覆盖接入分级策略、API 用法、速率与坐标系坑、版本兼容（iOS 17/17.4/18+）与真机验证流程。
---

# DockKit 云台适配（以 Insta360 Flow 2 Pro 为目标硬件）

DockKit（iOS 17+）让 iPhone 作为电动云台的计算中枢：系统级主体检测 + 电机控制，360° 水平 / 90° 俯仰追踪。**任何使用 AVFoundation 相机管线的 App 自动获得基础系统追踪**——适配工作的本质是决定你要不要、以及在哪一层接管。

## 接入分级（先确定要在哪一层做适配）

| 级别 | 你要做什么 | 适用 |
|---|---|---|
| L0 零代码 | 什么都不写；`AVCaptureSession.startRunning()` 即获得系统追踪 | 验证兼容性、视频通话/直播类 App |
| L1 状态感知 | 订阅 dock/undock，显示"云台已连接"UI、追踪状态指示 | 所有相机 App 建议做 |
| L2 构图接管 | `setFramingMode` / `setRegionOfInterest` 控制主体在画面中的位置 | 有 UI 遮挡（logo/字幕）、非标准画幅 |
| L3 追踪接管 | 关系统追踪，自己的 ML/Vision 模型喂 `track(observations:)` | 追踪非人物体（宠物、手、商品） |
| L4 电机/动画 | `setAngularVelocity` / `setOrientation` / `animate` | 运镜预设、手势触发云台动作（yes/no/kapow） |

**要诀：L3/L4 之前必须 `setSystemTrackingEnabled(false)`，做完必须恢复（动画完成、回前台、App 退出前）。**

## Flow 2 Pro 硬件适配要点

- 兼容性门槛：iPhone 12 及后续机型（**iPhone SE 3 与 16e 不支持 DockKit**），iOS 17+；iOS 18+ 解锁拍照/慢动作/电影效果/人像模式追踪与智控轮盘（变焦拨轮、切换前后摄）。配对走 NFC 一触或蓝牙（设备名 `Flow 2 Pro Dock XXXXXX`）。
- Flow 2 Pro 特性：360° 水平**无限位**旋转、360° 自由俯仰——`setLimits` 设运动范围时注意不要按有限位云台（Flow 2 平移轴 -210°~120°）的假设写死。
- 云台物理按键通过 `accessoryEvents`（iOS 17.4+）到达 App：`.cameraShutter`（快门）、`.cameraFlip`（前后翻转）、`.cameraZoom(factor:)`（变焦拨轮）、`.button(id:pressed:)`。第三方 App 要自己把这些事件映射到 AVFoundation 操作（拍照/切镜头/设 `videoZoomFactor`）。
- DockKit 系统追踪只认**人**（脸+身体）；Flow 2 Pro 的宠物/物体追踪（Deep Track 4.0）只在 Insta360 自家 App 里——你的 App 要追踪非人主体必须走 L3 自定义 observation。

## 核心代码骨架

```swift
import DockKit

// L1：发现云台（dock/undock 是仅有的两个必处理状态）
for await change in try DockAccessoryManager.shared.accessoryStateChanges {
    switch change.state {
    case .docked:
        guard let dock = change.accessory else { continue }
        // dock.identifier / firmwareVersion / hardwareModel；change.trackingButtonEnabled 为云台追踪键状态
        self.accessory = dock
    case .undocked: self.accessory = nil
    @unknown default: break
    }
}

// L2：构图（overlay 在左就让主体偏右；方形画幅设 ROI，原点左上角、归一化）
try await accessory.setFramingMode(.right)
try await accessory.setRegionOfInterest(CGRect(x: 0.25, y: 0, width: 0.5, height: 1))

// L3/L4 前置：关闭系统追踪（不持久！回前台要重设）
try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
```

完整 API（自定义追踪 observation、电机控制、动画、trackingStates 主体选择、batteryStates、速率限制与坐标系坑）见 [references/dockkit-api.md](references/dockkit-api.md)。

## 硬性约束（踩坑高发区）

1. **模拟器不支持 DockKit**——必须真机 + 实体云台调试；所有 DockKit 代码路径要可在无配件时优雅降级。验证流程用 `iphone-linked-dev` skill 的真机路线（devicectl 装 App + 控制台日志）。
2. **速率限制**：`track()` 需 10–30 fps（挂在 `AVCaptureVideoDataOutputSampleBufferDelegate` 上）；`animate` / `setOrientation` ≤ 2 次/秒，否则抛 `.frameRateTooHigh`。
3. **坐标系**：observation 的 `rect` 是归一化、**左下角**原点（同 Vision，无需转换）；`setRegionOfInterest` 是**左上角**原点。别搞反。
4. **版本守卫**：`accessoryEvents` 需 `#available(iOS 17.4, *)`；`trackingStates` / `batteryStates` 需 `#available(iOS 18.0, *)`；所有 DockKit enum 的 switch 加 `@unknown default`。
5. **DockKit 集成在相机管理代码里，不是 UI 层**——没有活跃 capture session 时 DockKit 什么都不做（Apple DTS 明确答复）。
6. 相机权限常规处理（`NSCameraUsageDescription`）；DockKit 本身无额外 entitlement / Info.plist key。

## 排查"云台不追踪"清单

1. App 是否在用 AVFoundation 相机（而非仅显示图片）？capture session 是否 `startRunning()`？
2. 原相机里追踪是否正常 → 不正常则是配对/硬件问题：确认蓝牙里 `Flow 2 Pro Dock XXXXXX` 已连、云台指示灯亮、iOS ≥ 17（推荐 18）、机型 ≥ iPhone 12 非 SE/16e。
3. 原相机正常但你的 App 不行 → 检查是否某处 `setSystemTrackingEnabled(false)` 后没恢复；iOS 17 下只有"视频"模式支持系统追踪。
4. 高倍变焦下追踪抽搐 → 自定义追踪时 cameraIntrinsics 要随当前 zoom factor 重算（见 api 文档"相机信息"节）。

## 与现有 skill 协同

- **ios-camera-ui**：相机界面设计规范（预览层、控制条、状态 pill）——云台连接状态建议做成状态 pill。
- **iphone-linked-dev**：真机构建/部署/日志验证闭环（DockKit 无法模拟器验证）。
