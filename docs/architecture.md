# ScreenAim 架构

## 一句话

iPhone 相机对着 Mac 屏幕 → Mac 识别屏幕四角的 ArUco 标记 → 单应矩阵把"帧中心（瞄准点）"
换算成屏幕逻辑坐标。

## 系统拓扑

```
┌────────────── iPhone (ios/AimPhone) ──────────────┐
│ AVCaptureSession 720p ──► CameraStreamer          │
│   手动曝光 1/120s（抑制屏幕条纹）                    │
│   Vision 二维码识别（未连接时）                      │
│   JPEG 编码 0.6 @ 15fps ──► TLVTransport ──┐        │
│ GimbalManager（DockKit 云台按键/状态）              │
└────────────────────────────────────┼──────────────┘
                                     │ TLV 消息流（protocol.md §11，type 0/1/10/11）
                                     │ Bonjour: _aimphone._tcp（9100 单端口）
┌────────────── Mac (ScreenAim) ─────▼──────────────┐
│ FrameServerV2 ──► ScreenSampler.processJPEG       │
│ （或 ScreenCaptureKit 本机采屏 ──► processBGRA）    │
│        │                                          │
│        ▼                                          │
│ OpenCVBridge：ArUco 检测（DICT_4X4_50，id0–7）     │
│        │ 8 个标记中心（匹配 ≥4 即求解）              │
│        ▼                                          │
│ findHomography(RANSAC) ──► 帧中心映射 ──► One Euro │
│ 滤波 ──► onAim                                    │
│ Calibrator：透明悬浮标定层（8 标记 + 配对二维码）    │
└───────────────────────────────────────────────────┘
```

## 模块划分

| 模块 | 文件 | 职责 | 依赖方向 |
|---|---|---|---|
| OpenCVBridge | `Sources/OpenCVBridge/` | ObjC++ 封装 `cv::aruco` 检测、标记生成、单应映射（`getPerspectiveTransform` / `findHomography` RANSAC） | 只依赖 OpenCV |
| ScreenAimCore | `Sources/ScreenAimCore/` | 纯 Swift 定位核（双端共享）：ArUco 检测（含亚像素角点精化）、单应（四点 DLT / RANSAC+最小二乘）、仿射兜底（3 点闭式解 + 凸包护栏，ADR-013）、输出滤波（`AimCoastFilter`：One Euro + 跳变门限 + 断帧滑行，ADR-014） | 只依赖 Accelerate |
| ScreenSampler | `Sources/ScreenAim/main.swift` | 帧入口（SCStream / JPEG）→ 检测 → RANSAC 映射 → One Euro 滤波 → `onAim` 回调 | → OpenCVBridge / ScreenAimCore |
| FrameServerV2 | `Sources/ScreenAim/FrameServerV2.swift` | TLV 单连接帧服务（视频/控制/采集回传，§11）+ Bonjour 广播；`CaptureIngestor` 采集落盘 | → ScreenSampler.processJPEG |
| Calibrator | `Sources/ScreenAim/main.swift` | 透明悬浮标定层：8 标记（4 角 + 4 边中点，ADR-007）、配对二维码、自动填映射表 | → ScreenSampler / FrameServerV2 |
| CameraStreamer | `ios/AimPhone/CameraStreamer.swift` | 相机采集、JPEG 推流、连接管理、扫码配对（传输核心 `TLVTransport`，§11） | 无（叶子模块） |
| GimbalManager | `ios/AimPhone/GimbalManager.swift` | DockKit 云台状态/按键事件 → 注入的动作闭包 | 无（叶子模块） |
| ContentView | `ios/AimPhone/ContentView.swift` | 全部 UI + 手势状态机 + 云台按键动作注入 | → 上面两者 |

设计原则：**Mac 做识别，手机只做采集**；手机端不依赖任何识别结果，两端可独立替换。

## 运行模式（Mac 端命令行互斥分支）

1. `--self-test`：离线自检（生成场景 → 检测 → homography 验证），无屏幕权限也能跑。
2. `--make-markers DIR`：离线生成校准标记 PNG。
3. `--calibrate [--serve PORT]`：生产模式。悬浮标定层 + 采样/推流识别，阻塞进 App 主循环。
4. 无参数：仅采样，`screenCornerMap` 用硬编码示例值（调试用）。

## 线程模型

| 队列/上下文 | 跑什么 |
|---|---|
| `screenaim.sampler`（串行） | SCStream 帧回调 → `processBGRA`（检测→映射→滤波） |
| `screenaim.server` / `screenaim.conn` | NWListener  accept 与读帧、控制帧内联分发 |
| `screenaim.frames`（串行） | 手机视频帧的 `processJPEG`（识别慢于到达率时丢旧帧保最新） |
| main runloop（Mac） | Calibrator 窗口、定时器、`onAim` 消费方 |
| `aimphone.capture`（串行，iOS） | 采集回调、JPEG 编码、扫码识别、曝光/变焦/翻转配置 |
| `@MainActor`（iOS） | GimbalManager 全部状态与事件分发、UI |

约定：**像素数据永不进主线程**；UI 状态全部通过 `@Published` 回主线程。

## 输出滤波分层（ADR-014）

瞄准点滤波分两段，参数显式分离（`AimFilterPreset.phone` / `.macDisplay`），
口语化调参见 docs/aim-filter-tuning.md：

```
iPhone 识别段（ScreenLocalizer.aimFilter，15Hz，相机 PTS 时间轴）
  = One Euro 强消抖 + 跳变门限 + 断帧滑行   ← 消抖主战场，噪声在哪产生在哪滤
Mac 显示段（Calibrator.dotFilter，≈15Hz 上报到达墙钟）
  = 轻插值平滑 + 跳变门限 + 断流滑行        ← 不重复消抖，否则横扫滞后双段叠加
```

两段共用 `AimCoastFilter` 同一实现；消抖必须留在 iPhone 段（网络到达抖动会污染
滤波时间轴，protocol.md §11 Nagle 攒批实测即证据）。

## 坐标系约定（易错点）

| 坐标系 | 原点 | 单位 | 用在哪 |
|---|---|---|---|
| 帧像素坐标 | 左上 | px | ArUco 检测结果（`ArucoMarker.center`） |
| 屏幕逻辑坐标 | 左上 | pt | `screenCornerMap`、映射输出、`onAim` |
| NSView/AppKit | 左下 | pt | Calibrator 布局时需要 `y = H - y` 翻转 |
| UIKit/SwiftUI | 左上 | pt | iOS 端无需转换 |

Homography 自动吸收采样降采样比例：**dst 用什么单位，输出就是什么单位**。
