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
| `ArucoDetector` | 纯 Swift ArUco 检测（DICT_4X4_50 id0–7）：自适应阈值 + 连通域 + 字典匹配；亚像素角点精化（法向剖面 + TLS 直线拟合，`subpixelRefine` 可关）；候选 prefilter（几何 + 边缘对比指纹）后 `maxCandidates` 解码上限（按四边最弱对比度降序截断，防噪点拖垮 decode）；`rejectHistogram` 拒绝原因计数（回放调参用） |
| `DetectedMarker` | 检测结果：`id` / `center` / `corners`（帧像素，左上原点） |
| `Homography` | 3×3 单应：`init(src:dst:)` 四点 DLT；`init(ransacSrc:dst:thresholdPx:maxIter:)` RANSAC + Accelerate `dsyev_` 最小二乘精化（ADR-007） |
| `AffineTransform` | 二维仿射 6 参数：恰好 3 对对应点 Cramer 闭式解（WP1.1 定位兜底，ADR-013）；不能外推透视，须配合凸包护栏使用 |
| `AimCoastFilter` | 瞄准点二维输出滤波统一实现（ADR-013/014，双端共用）：One Euro 消抖 + 跳变门限（k×max(σ̂, 下限)，滑行后首帧旁路）+ 断帧滑行（速度 ≈100ms 半衰期衰减，默认最多 5 帧）；只读接口 `displayExtrapolation(at:)`（WP-L1，ADR-015）= 匀速死推算显示外推（时距封顶 120ms，不改滤波状态）；iPhone `ScreenLocalizer.aimFilter` 与 Mac `Calibrator.dotFilter` 各持一个实例 |
| `AimFilterPreset` | 口语化预设三档（`stable`/`daily`/`fast`，WP3.3 分层解耦）：`phone` = iPhone 识别段强消抖参数，`macDisplay` = Mac 显示段轻插值参数；人话映射表 docs/aim-filter-tuning.md |
| `ScreenLocalizer` | 检测→映射→滤波编排：`screenCornerMap` ≥3 项即可；≥4 对 RANSAC 单应、恰好 3 对仿射兜底 + 1.5× 凸包护栏、检出不足走滑行（`quality` 三级：homography/affine/coast）；`solveAim`/`processMatches` 公开供自检直注合成匹配点；输出滤波 `aimFilter`（AimCoastFilter，`aimFilterEnabled` 可关） |
| `OneEuroFilter` | One Euro 低通（minCutoff=1.0 / beta=0.5 / dCutoff=1.0），时间戳外部传入；`value`/`velocity` 只读暴露当前低通输出与速度（滑行外推的数据源）；连续 10 帧无输出由 Localizer/Sampler 重置 |
| `ArucoDictionary` | id0–7 位图表 + 4 旋转查表（精确 → 汉明距 1 纠错） |
| `TLVMessageType` | TLV 消息类型号（protocol.md §11）：video=0 / control=1 / captureMeta=10 / captureFrame=11；线上常量双端共享 |

| `FrameServerV2` | TLV 单连接帧服务（protocol.md §11，9100 端口，Bonjour `_aimphone._tcp`，P3 起唯一传输服务）：NetworkListener + 内置 TLV framer，`messages` 按 type 分发 0/1/10/11；`onFrame` 交 JPEG，`onConnect` 通知已配对，`onControl` 分发控制消息（§6/§7/§8），`onDisconnect` 断连回调（鼠标键卡死兜底，ADR-008），`handshakePayload` 连接即下发标定表，采集回调 `sessionInfo`/`onCaptureDone`；采集落盘经文件内私有 `CapturePipeline` 有界管道（容量 8，enqueue 挂起即背压）异步消费，接收循环不再被磁盘 I/O 卡住；**`TCP().noDelay(true)` 必开**（§11） |
| `CaptureIngestor` | 采集落盘器（type 10/11）：落盘 `scenes/capture_*/` 三件套（frames/NNNN.png + meta.jsonl + session.json 双端合并），中途断连按已收帧数兜底收尾 |

### `Sources/ScreenAim/main.swift`

| 类型/函数 | 说明 |
|---|---|
| `ScreenSampler` | 帧处理中枢：`start()` 起 SCStream；`processJPEG` / `processBGRA` 两条入口汇到同一检测映射管线（RANSAC 映射 + One Euro 输出滤波）；`screenCornerMap` 填 ≥4 个标记的屏幕坐标后输出 `onAim`；`onMarkersDetected` 每帧回调检出标记 ID（标定层绿边的数据源）；FPS 日志带 `det=xxms` 检测耗时 |
| `primaryIPv4()` | 本机主网卡 IPv4（优先 en0），配对二维码用 |
| `makeQRImage` / `makeStyledQRImage` | 二维码 NSImage 生成（普通 / 小程序码圆点风格） |
| `Calibrator` | 透明悬浮标定层：8 标记（4 角 + 4 边中点，自带白色底卡保证静区）、中央配对二维码、IP 变化看守、ESC 退出；`run()` 阻塞进主循环；`setMarkerActivation` 标记激活绿边、`markerAlpha` 白卡不透明度滑杆（0.4–1.0）、`aimDot` localAim 白点覆盖层（`dotFilter` = Mac 显示段 AimCoastFilter：插值平滑 + 跳变门 + 断流滑行，参数来自 `--filter-preset` / `--dot-*`，预设经 calib `filterPreset` 字段下发 iPhone 识别段；60Hz 显示定时器 WP-L1/ADR-015 用 `displayExtrapolation` 在两次上报空窗内匀速死推算摆点，摆点换算统一走 `placeAimDot`）、`aimCursor`（`--aim-cursor`）瞄准点绑光标；鼠标模拟器 `handleMouseButton` / `releaseStuckMouseButtons`（ADR-008）；localAim 写 `scenes/localaim_*.csv`（列含 detect_ms/src/quality），鼠标事件写 `scenes/mouse_*.csv`（`logMouseEvent`，列 timestamp,event,button,delta） |
| `postMouseDown/Up/Click/Scroll` | 鼠标模拟器事件注入（protocol.md §8）：当前光标位置 CGEvent 按下/抬起/点击/滚轮；需辅助功能授权，否则事件被系统静默丢弃 |

命令行自检/基准：`--self-test`（OpenCV 管线，8 标记 + 遮挡模拟 + WP1 仿射兜底/护栏/滑行
合成场景）、`--swift-self-test`（纯 Swift 管线同款判据）、`--swift-detect IMG [GT] [--verbose]`
（双检测器对比）、`--swift-seq IMGS... [--cutoff C --beta B]`（序列 σ 基准，Phase 1.3 验收工具）、
`--filter-self-test`（WP3 滤波层验收：静止 σ 回归 / 单帧 15pt 跳变门 / 断流滑行 / 预设横扫滞后 /
WP-L1 显示外推（匀速 +33/+66ms 误差 / 静止漂移 / 120ms 封顶），确定性合成信号）、`--replay DIR [--min-cell-gap X] [--thresh-c X] [--window N] [--no-refine]`
（采集会话回放：线上/离线/OpenCV 参照三方命中率 + 中心误差 + aim σ + 拒绝直方图 +
匹配对数/quality 分布与三点簇转化率 + replay.csv）。
生产模式调参：`--filter-preset stable|daily|fast` + 单项旋钮
`--dot-min-cutoff/--dot-beta/--dot-coast-frames/--dot-gate-k`（docs/aim-filter-tuning.md）。

## iOS 端（ios/AimPhone，XcodeGen 工程）

### `CameraStreamer.swift`

| 成员 | 说明 |
|---|---|
| `CameraAvailability` | unknown / available / unauthorized / failed(String)，驱动兜底 UI |
| `setBrightness(_:)` | v∈0...1 → ISO [minISO, minISO×10]，手动曝光 1/120s 不变 |
| `setZoomFactor(_:)` / `adjustZoom(delta:)` / `zoomFactor` | 数码变焦（ADR-019）：绝对倍率（二指手势）与乘法增量（轮盘，一格 ≈5%）双入口，共用 videoQueue 执行核 `applyZoom`，钳 [设备下限, min(3×, 设备上限)]（≈3.1× 内不丢有效分辨率）；`zoomFactor` 主线程只读供 UI 倍率指示与手势基线；切前后摄回 1× |
| `flipCamera` / `toggleStreamPaused` | 云台按键映射的相机操作 |
| `connect(host:port:)` / `connectEndpoint(_:label:)` / `disconnect()` | 连接管理（TLV 单一协议，§11；看门狗 5s×6 在 TLVTransport 内）；扫码兼容读过渡期二维码的 port2 字段 |
| `startBrowsing()` | Bonjour 自动发现 `_aimphone._tcp`（主方案） |
| `scanQRCode()` / `cancelScan()` | 主动扫码（5 秒窗口逐帧搜索）；未连接时也有 0.3s 间隔的被动扫码 |
| `onScanned` | 扫码成功回调（UI 回填地址） |
| `localizeFrame(_:timestamp:)` | 本机识别 + localAim 每次识别都上报（不抽稀、不降频，ADR-009/ADR-020）+ 采集抽帧入口；恒定 15Hz 识别（不主动降频，ADR-020）：`localizeIntervalFull` = 1/15s 对齐发送闸门，识别在独立串行队列 `aimphone.localize` 上执行 + NSLock busy 闸门 `localizeInFlight` 丢旧保新（与 Mac 端 `frameInFlight` 同构，CR2；识别慢只被动降识别频率，不阻塞 videoQueue 推流） |
| `sendMouseDown/Up` / `sendMouseScroll` / `sendMouseClick` | 横屏鼠标模拟器上报（§8）：按下/抬起分离（`button:"all"` 为断连兜底，ADR-008）、滚轮刻度；`sendMouseClick` 为旧协议保留 |
| 对焦锁定状态机（P0，ADR-018） | 内联两态（focusing/locked）：`focusFeed(markerCount:)` 随 `localizeFrame` 喂入检出数（CR2 起调用方在 localizeQueue，经 async 跳回 videoQueue 执行状态机本体）——连续 1s 检出 ≥6/8 且决策点 `isAdjustingFocus == false` → `setFocusModeLocked(lensPosition:)`；锁定中连续 10 次识别 <4 → 解锁重 AF。`applyDeviceSettings` 增补帧中心 `focusPointOfInterest` + `.near` 范围限制；能力不支持静默降级纯 CAF。`requestRefocus()` 为 P1/P1.5 手动干预预留的解锁入口（本批次不接事件） |

### `TLVTransport.swift`

TLV 单连接传输（protocol.md §11，CameraStreamer 的传输核心，P3 起唯一传输路径）：NetworkConnection +
内置 TLV framer；看门狗重试（5s×6，establishmentReport 与超时竞争）；`send(jpeg:)` type 0 /
`sendControl` type 1（sendIdempotent）/ `uploadCapture` type 10/11（await send 串行背压，
并入主连接无第二端口）；`disconnectGracefully` 补发 mouseUp all + disconnect 并以
lastMessage 收尾（ADR-008 语义不变）。事件/控制回调全部主线程派发。

### `CaptureRecorder.swift`

真机数据采集（protocol.md §10/§11）：Mac 控制帧触发，无损 PNG + meta.jsonl 录到临时目录，
录完经主 TLV 连接 type 10/11 上传（`TLVTransport.uploadCapture`）。全部在
`aimphone.capture` 队列，UI 零改动（进度复用 `statusText`）。
WP-I1 起 meta.jsonl 每帧追加 `motion` 字段（帧 PTS ±0.15s 的 100Hz 运动样本，
只加不删）；meta 因此延迟一帧写出（`pendingMeta`/`flushPendingMeta`）。

### `MotionSampler.swift`

CoreMotion deviceMotion 100Hz 采样器（IMU 辅助定位 WP-I1，docs/imu-fusion-plan.md §1）：
只采不融，跟随采集会话启停（CaptureRecorder 持有，全 app 唯一 CMMotionManager 持有者），
样本时间戳与相机帧 PTS 同为 mach boot 时钟。`window(around:half:)` 供 meta 补帧前后样本，
`latestRotRate()` 供每帧 rotRate 字段。对识别/推流/协议零影响。

### `GimbalManager.swift`

DockKit 云台适配层（`#if canImport(DockKit)` 守卫，模拟器全降级）。
类头 doc comment 即按键映射完整说明，此处只列注入点：

| 闭包 | 语义（由 ContentView 注入） |
|---|---|
| `onShutter` | 快门键 → 扫码配对 / 取消扫码（需按住扳机） |
| `onFlip` | 翻转键 → 连接 Mac / 断开（需按住扳机） |
| `onZoomDelta` | 轮盘增量 → 数码变焦（需按住扳机；ADR-019，原为亮度） |

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
| `MousePadOverlay` | 横屏鼠标模拟器触控层（§8）：左/右键落指发 down、抬指发 up（支持拖拽），滚轮竖拖逐格上报 + 轻点中键 down+up |
| `View.glass*` 扩展 | Liquid Glass（iOS 26+）兼容封装，旧系统回退 ultraThinMaterial |

## 工作区内的过程文档

| 文件 | 说明 |
|---|---|
| `button-mapping-plan.md` | DockKit 按键映射方案设计稿 |
| `*.skill` / `*/SKILL.md` | 沉淀的 Agent 技能（dockkit-gimbal、dockkit-button-mapping、ios-camera-ui、iphone-linked-dev） |
| `aimphone_*.png` | UI 迭代截图（设计评审记录） |
