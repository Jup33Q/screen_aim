# DockKit API 详解

## 目录

- 自定义追踪（L3）：Observation / CameraInformation / track
- 电机直控（L4）：setAngularVelocity / setOrientation / motionStates / setLimits
- 内置动画：animate
- 追踪状态与主体选择（iOS 18+）：trackingStates / selectSubjects
- 云台按键事件（iOS 17.4+）：accessoryEvents → AVFoundation 映射
- 电量监控（iOS 18+）：batteryStates
- 常见错误模式（DON'T 清单）
- 参考资料

## 自定义追踪（L3）

关闭系统追踪后，以 **10–30 fps** 向云台喂观察结果（挂在 `AVCaptureVideoDataOutputSampleBufferDelegate` 回调上）：

```swift
import DockKit
import AVFoundation

func processFrame(_ sampleBuffer: CMSampleBuffer,
                  accessory: DockAccessory,
                  activeDevice: AVCaptureDevice) async throws {
    let cameraInfo = DockAccessory.CameraInformation(
        captureDevice: activeDevice.deviceType,
        cameraPosition: activeDevice.position,
        orientation: .corrected,              // 坐标已相对左下角时用 .corrected
        cameraIntrinsics: intrinsics(from: sampleBuffer),  // 见下方"相机内参"
        referenceDimensions: frameDimensions(from: sampleBuffer)
    )

    let detection = try await detector.detect(sampleBuffer)  // Vision / CoreML / 启发式
    let type: DockAccessory.Observation.ObservationType = switch detection.kind {
    case .face: .humanFace
    case .body: .humanBody
    case .object: .object                     // 仅这三种类型
    }
    let observation = DockAccessory.Observation(
        identifier: detection.id,             // 同一主体跨帧保持同一 id
        type: type,
        rect: detection.rect,                 // 归一化 + 左下角原点（同 Vision，无需转换）
        faceYawAngle: detection.faceYawAngle  // 可选
    )
    try await accessory.track([observation], cameraInformation: cameraInfo)
}
```

- `track` 也有接收 `[AVMetadataObject]` 的重载；带 `image: CVPixelBuffer` 的重载中 image 参数**必填**。
- 遮挡容错：系统统计追踪器会在你的推理短暂出错时纠正，不必每帧都有结果，但要保持频率。

### 相机内参（CameraInformation）

不要硬编码占位值——从当前 `AVCaptureDevice` + 当前 `CMSampleBuffer` 现算：

- 优先从 sample buffer 附件读真实内参：`CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, ...)`。
- 读不到时估算：`fx = fy = 对角线像素 × 0.8 × 当前 zoomFactor`，`cx = w/2, cy = h/2`。**变焦会改变内参**——高倍变焦下追踪抽搐多半是内参没随 zoom 更新。

## 电机直控（L4）

前置：`setSystemTrackingEnabled(false)`。坐标轴（`Spatial.Vector3D`，弧度制）：

- `x` = pitch 俯仰（iOS 上正值低头）
- `y` = yaw 水平（正值向右转）
- `z` = roll（视硬件支持）

```swift
import Spatial

// 连续速度：向右 0.2 rad/s + 低头 0.1 rad/s；停止 = Vector3D()
try await accessory.setAngularVelocity(Vector3D(x: 0.1, y: 0.2, z: 0))

// 定点转动：2 秒内转到 yaw 0.5 rad；relative: true = 相对当前位置
let progress = try accessory.setOrientation(Vector3D(x: 0, y: 0.5, z: 0),
                                            duration: .seconds(2), relative: false)

// 实时位姿监控
for await state in try accessory.motionStates {
    state.angularPositions   // Vector3D
    state.angularVelocities  // Vector3D
    state.error              // 电机错误
}

// 运动范围/限速（Flow 2 Pro 水平无限位，不要把范围按有限位云台写死）
let yawLimit = try DockAccessory.Limits.Limit(positionRange: -1.0..<1.0, maximumSpeed: 0.5)
try accessory.setLimits(DockAccessory.Limits(yaw: yawLimit, pitch: nil, roll: nil))
```

## 内置动画

```swift
try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
let progress = try await accessory.animate(motion: .kapow)   // .yes 点头 / .no 摇头 / .wakeup / .kapow 钟摆
while !progress.isFinished && !progress.isCancelled {
    try await Task.sleep(for: .milliseconds(100))
}
try await DockAccessoryManager.shared.setSystemTrackingEnabled(true)  // 必须恢复
```

动画从当前位置开始、异步执行；典型用法是手势识别触发（如"推手"手势 → kapow 后甩）。`animate` 和 `setOrientation` 合计 ≤ 2 次/秒。

## 追踪状态与主体选择（iOS 18+）

```swift
if #available(iOS 18.0, *) {
    for await state in try accessory.trackingStates {
        for subject in state.trackedSubjects {
            switch subject {
            case .person(let p):
                // p.identifier, p.rect（画 overlay）
                // p.speakingConfidence > 0.7 → 正在说话
                // p.lookingAtCameraConfidence > 0.7 → 看向镜头
                // p.saliencyRank 越小越显著（兜底选择依据）
                break
            case .object(let o): break  // o.identifier / o.rect / o.saliencyRank
            }
        }
    }
}
try await accessory.selectSubjects([uuid])   // 锁定主体；传 [] 恢复自动选择
try await accessory.selectSubject(at: CGPoint(x: 0.5, y: 0.5))  // 点选（单位坐标）
```

策略建议：speaker ?? engaged ?? saliencyRank 最小者 → `selectSubjects` 锁定。已知问题：iOS 18 早期版本部分字段（speakingConfidence 等）可能取不到值，做好 nil 处理。

## 云台按键事件（iOS 17.4+）→ AVFoundation 映射

```swift
if #available(iOS 17.4, *) {
    for await event in try accessory.accessoryEvents {
        switch event {
        case .cameraShutter:                    capturePhoto()            // 拍照/起停录像
        case .cameraFlip:                       flipCamera()              // 切换前后摄
        case .cameraZoom(let factor):           device.videoZoomFactor = factor  // 智控轮盘变焦
        case .button(let id, let pressed):      handleButton(id, pressed) // 扳机键等
        @unknown default: break
        }
    }
}
```

Flow 2 Pro 按键参考（iOS 18 原相机行为，第三方 App 需自行实现）：扳机单击=开始/结束追踪，双击=云台回中，三击=前后翻转；拨轮=变焦；切换键单击=前后摄、双击=横竖屏。

## 电量监控（iOS 18+）

```swift
if #available(iOS 18.0, *) {
    for await battery in try accessory.batteryStates {
        // 多电池云台用 battery.name 区分；batteryLevel / chargeState / lowBattery
    }
}
```

## 常见错误模式（DON'T 清单）

1. ❌ 没关系统追踪就 `setAngularVelocity` → 系统追踪与手动指令打架，云台抖动。
2. ❌ 假设追踪状态跨生命周期持久 → 回前台/重启后必须重设 `setSystemTrackingEnabled`。
3. ❌ `track()` 1 fps → 太慢，追踪漂移；必须 10–30 fps。
4. ❌ 动画/定点转动写 tight loop → `.frameRateTooHigh`；设好轨迹观察 `Progress` 即可。
5. ❌ 动画结束忘了恢复系统追踪。
6. ❌ 在模拟器跑 DockKit 代码路径 → 必须真机 + 实体云台；无配件时优雅降级。
7. ❌ ROI 和 observation rect 坐标系搞混：ROI 左上原点，observation rect 左下原点。

## 参考资料

- Apple 文档：DockKit framework / DockAccessoryManager / DockAccessory / DockKitError
- 官方教程：Controlling a DockKit accessory using your camera app；Track custom objects in a frame；Modify rotation and positioning programmatically
- WWDC23 Session 10304：Integrate with motorized iPhone stands using DockKit
- WWDC24：What's new in DockKit（iOS 18 高级追踪管道、ML 选主体、Apple Watch 遥控）
- Insta360 Flow 2 Pro 在线手册：onlinemanual.insta360.com/flow2pro（第三方 App 兼容性列表 + DockKit 追踪异常排查）
