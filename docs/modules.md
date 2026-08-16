# 模块索引

逐文件的职责说明与公开 API。函数级细节以源码内 doc comment（`///`）为准，
本文只给"去哪找什么"的地图。

## Mac 端（SwiftPM 包 ScreenAim）

### `Sources/OpenCVBridge/`（Objective-C++）

| API | 说明 |
|---|---|
| `ArucoMarker` | 检测结果：`markerId` / `center`（帧像素）/ `corner0` |
| `detectMarkersInBGRABuffer:width:height:` | 紧凑 BGRA → ArUco 检测（DICT_4X4_50，亚像素角点精化） |
| `detectMarkersInImageFile:` | 离线自检用 |
| `generateTestSceneToFile:error:` | 生成 1000×800 自检场景（8 标记：4 角 + 4 边中点，边长 100px） |
| `markerPNGWithId:sidePixels:` | 内存生成单标记 PNG（供 NSImage 直接显示） |
| `generateMarkersToDirectory:count:sidePixels:error:` | 批量生成校准标记到目录 |
| `mapPoint:srcPoints:dstPoints:success:` | 4 组对应点求单应并映射一个点 |
| `mapPointRANSAC:srcPoints:dstPoints:success:` | ≥4 组对应点 `findHomography(RANSAC, 3.0)` 映射（冗余标记，ADR-007） |

OpenCV 路径硬编码 `/opt/homebrew/opt/opencv`（Apple Silicon Homebrew），
在 `Package.swift` 顶部改。

### `Sources/ScreenAimCore/`（纯 Swift，iOS/macOS 双端共享）

| API | 说明 |
|---|---|
| `ArucoDetector` | 纯 Swift ArUco 检测（DICT_4X4_50 id0–7）：自适应阈值 + 连通域 + 字典匹配；亚像素角点精化（法向剖面 + TLS 直线拟合，Phase 1.2） |
| `DetectedMarker` | 检测结果：`id` / `center` / `corners`（帧像素，左上原点） |
| `Homography` | 3×3 单应：`init(src:dst:)` 四点 DLT；`init(ransacSrc:dst:thresholdPx:maxIter:)` RANSAC + Accelerate `dsyev_` 最小二乘精化（ADR-007） |
| `ScreenLocalizer` | 检测→映射→滤波编排：`screenCornerMap` ≥4 项即可；输出侧内嵌 One Euro 滤波（`aimFilterEnabled` 可关，`aimFilterX/Y` 可调参） |
| `OneEuroFilter` | One Euro 低通（minCutoff=1.0 / beta=0.5 / dCutoff=1.0），时间戳外部传入；连续 10 帧无输出由 Localizer/Sampler 重置 |
| `ArucoDictionary` | id0–7 位图表 + 4 旋转查表（精确 → 汉明距 1 纠错） |

### `Sources/ScreenAim/main.swift`

| 类型/函数 | 说明 |
|---|---|
| `ScreenSampler` | 帧处理中枢：`start()` 起 SCStream；`processJPEG` / `processBGRA` 两条入口汇到同一检测映射管线（RANSAC 映射 + One Euro 输出滤波）；`screenCornerMap` 填 ≥4 个标记的屏幕坐标后输出 `onAim`；FPS 日志带 `det=xxms` 检测耗时 |
| `primaryIPv4()` | 本机主网卡 IPv4（优先 en0），配对二维码用 |
| `makeQRImage` / `makeStyledQRImage` | 二维码 NSImage 生成（普通 / 小程序码圆点风格） |
| `FrameServer` | TCP 帧服务 + Bonjour 发布；`onFrame` 交 JPEG，`onConnect` 通知已配对 |
| `Calibrator` | 透明悬浮标定层：8 标记（4 角 + 4 边中点，自带白色底卡保证静区）、中央配对二维码、IP 变化看守、ESC 退出；`run()` 阻塞进主循环；localAim 写 `scenes/localaim_*.csv`（列含 detect_ms/src） |

命令行自检/基准：`--self-test`（OpenCV 管线，8 标记 + 遮挡模拟）、`--swift-self-test`
（纯 Swift 管线同款判据）、`--swift-detect IMG [GT] [--verbose]`（双检测器对比）、
`--swift-seq IMGS... [--cutoff C --beta B]`（序列 σ 基准，Phase 1.3 验收工具）。

## iOS 端（ios/AimPhone，XcodeGen 工程）

### `CameraStreamer.swift`

| 成员 | 说明 |
|---|---|
| `CameraAvailability` | unknown / available / unauthorized / failed(String)，驱动兜底 UI |
| `setBrightness(_:)` | v∈0...1 → ISO [minISO, minISO×10]，手动曝光 1/120s 不变 |
| `setZoomFactor` / `flipCamera` / `toggleStreamPaused` | 云台按键映射的相机操作 |
| `connect(host:port:)` / `connectEndpoint(_:label:)` / `disconnect()` | 连接管理（5s 看门狗 + 6 次重试） |
| `startBrowsing()` | Bonjour 自动发现（主方案） |
| `scanQRCode()` / `cancelScan()` | 主动扫码（5 秒窗口逐帧搜索）；未连接时也有 0.3s 间隔的被动扫码 |
| `onScanned` | 扫码成功回调（UI 回填地址） |

### `GimbalManager.swift`

DockKit 云台适配层（`#if canImport(DockKit)` 守卫，模拟器全降级）。
类头 doc comment 即按键映射完整说明，此处只列注入点：

| 闭包 | 语义（由 ContentView 注入） |
|---|---|
| `onShutter` | 快门键 → 扫码配对 / 取消扫码（需按住扳机） |
| `onFlip` | 翻转键 → 连接 Mac / 断开（需按住扳机） |
| `onZoomDelta` | 轮盘增量 → 亮度调节（需按住扳机） |

调试面板：`lastEvent` / `eventHistory`（最多 20 条）上屏显示，稳定后可移除。

### `ContentView.swift`

| 组件 | 说明 |
|---|---|
| `CameraPreview` / `PreviewView` | 根层即 AVCaptureVideoPreviewLayer；旋转交给 RotationCoordinator（三个同步时机缺一不可，见文件内注释） |
| `sunButton` | 单一 DragGesture 状态机：长按 0.35s 激活亮度条 + 竖拖调节；短按收起 |
| `controlCapsule` | 底部胶囊：太阳按钮 + 亮度条 + 扫码/取消 |
| `controlPanel` | 顶部连接面板（已连接折叠为 pill） |
| `gimbalPill` | 云台状态 + 扳机门控的按键功能图例 |
| `Crosshair` / `ScanOverlay` / `CornerBrackets` | 瞄准十字 / 扫码遮罩 / 取景框角标 |
| `View.glass*` 扩展 | Liquid Glass（iOS 26+）兼容封装，旧系统回退 ultraThinMaterial |

## 工作区内的过程文档

| 文件 | 说明 |
|---|---|
| `button-mapping-plan.md` | DockKit 按键映射方案设计稿 |
| `*.skill` / `*/SKILL.md` | 沉淀的 Agent 技能（dockkit-gimbal、dockkit-button-mapping、ios-camera-ui、iphone-linked-dev） |
| `aimphone_*.png` | UI 迭代截图（设计评审记录） |
