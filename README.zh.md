# ScreenAim — 屏幕采样 + ArUco 标记检测（macOS 端）

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-6.x-orange.svg?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B%20%7C%20iOS%2026%2B-lightgrey.svg?logo=apple)](https://www.apple.com/macos/)
[![OpenCV](https://img.shields.io/badge/OpenCV-5.0-blue.svg)](https://opencv.org)

手机瞄准投屏方案（路线 B / Mac 端识别）的最小可行实例：
**ScreenCaptureKit 采集屏幕帧 → OpenCV ArUco 标记检测 → 单应矩阵（homography）映射到屏幕坐标**。

实测：1728×1117 屏幕，1280 宽降采样，约 29 FPS，自检映射误差 < 1px。

## 文档

体系化文档见 [docs/](docs/README.md)：[架构](docs/architecture.md) ·
[通信协议](docs/protocol.md) · [模块索引](docs/modules.md) ·
[设计决策 ADR](docs/decisions.md) · [构建与排错](docs/development.md) ·
[注释系统规范](docs/comment-style.md)。改代码前请先读注释规范与相关 ADR。

## 依赖

```bash
brew install opencv   # 已装 OpenCV 5.0.0，含 aruco 模块
swift build           # Swift 6.x，无需 Xcode 工程
```

结构：
- `Sources/OpenCVBridge/` — Objective-C++ 桥接层，封装 `cv::aruco::ArucoDetector`、`getPerspectiveTransform`
- `Sources/ScreenAim/main.swift` — 采集、检测、映射主流程

## 用法

```bash
# 1. 离线自检：生成测试场景 -> 检测 8 标记 -> RANSAC 单应验证（含遮挡模拟）
swift run ScreenAim --self-test

# 2. 生成 8 个校准标记 PNG（id0–3 四角 + id4–7 四边中点）
swift run ScreenAim --make-markers ./markers

# 3. 透明悬浮标定层（推荐）：8 个悬浮小标记（4 角 + 4 边中点），自动标定 + 实时输出瞄准坐标
swift run ScreenAim --calibrate                          # 默认 48pt 标记
swift run ScreenAim --calibrate --marker-size 24         # 屏幕占位敏感时调小（识别距离会变近）
swift run ScreenAim --calibrate --inset 40 --pad 12      # 可调边距/白卡边距

# 4. 手机推流模式：TCP 收 JPEG 帧（配合 ios/AimPhone App）
swift run ScreenAim --calibrate --serve 9100
swift run ScreenAim --calibrate --serve 9100 --aim-cursor   # 追加：瞄准点绑定鼠标光标（手机瞄哪光标跟哪）

# 5. 仅采样（手工填 screenCornerMap 时用）
swift run ScreenAim
```

## 手机端（ios/AimPhone）

Xcode 工程由 XcodeGen 生成，零第三方依赖（纯 AVFoundation + Network）：

```bash
cd ios && xcodegen generate          # 重新生成工程（修改 project.yml 后）
open ios/AimPhone.xcodeproj          # 打开后选择你的 Development Team，部署到 iPhone
```

- 手机 App 只做：相机采集（720p，锁定 1/60s 曝光抑制屏幕条纹）+ 中心瞄准十字 + JPEG 推流
- **日常真机验证用 Release 构建**：Run scheme 已由 project.yml 固定为 Release（纯 Swift
  检测器 Debug 下慢 ~80 倍，2026-08-18 实测 detect_ms 8–15ms→640ms、localAim 1.5Hz）
- 协议：TCP `[4字节大端长度][JPEG数据]`，15fps，720p，延迟约 100ms
- Mac 端 `--calibrate --serve 9100` 同时显示悬浮标记并接收手机帧做识别
- 已用模拟推流验证：60/60 帧全检出，映射输出稳定

### DockKit 云台适配（Insta360 Flow 2 Pro 等）

- **人物追踪已关闭**：本 App 瞄准屏幕不需要追人，docked 时 `setSystemTrackingEnabled(false)`，退后台/退出时恢复
- **L1 状态感知**：`GimbalManager` 订阅 `DockAccessoryManager` dock/undock，顶部显示云台 pill（型号/电量 iOS 18+）
- **按键映射**（iOS 17.4+ `accessoryEvents`，动作闭包由 ContentView 注入）：
  - **扳机按住 = 功能修饰键**（`.button(id:)`，按住时机械臂锁定，pill 中 scope 图标变黄、功能图标点亮）
  - 智控轮盘 → **亮度调节**（需按住扳机；绝对倍率转增量，一格约 5%，带刻度触觉反馈；基线始终更新防跳变）
  - 快门键 → **扫码配对 / 取消扫码**（需按住扳机）
  - 翻转键 → **连接 Mac / 断开**（需按住扳机，用界面中保存的地址）
  - pill 图标：scope=扳机、sun.max=亮度、qrcode.viewfinder=扫码、link=连接
- DockKit 仅存在于真机 SDK，适配层用 `#if canImport(DockKit)` 守卫：模拟器编译自动降级为空操作；真机无配件时所有路径静默降级
- 验证要求：iPhone 12+（SE 3/16e 不支持）+ iOS 17+（建议 18）+ 实体云台，模拟器无法验证 DockKit 行为

### 标记尺寸实测（本机 1728×1117，1280 宽降采样采集）

| 标记边长 | 命中率 | 瞄准点抖动 σ |
|---|---|---|
| 64pt | ~100% | < 0.1pt |
| 24pt | ~100% | ≈ 0.05pt |
| 20pt | ~0% → 见下注 | — |
| 16pt | 0% | — |

注：上表是 Phase 1 优化前的真机实测。Phase 1.1–1.3 后（冗余 8 标记 + 亚像素角点
精化 + One Euro 滤波），合成基准场景（tools/make_bench_scenes.py，1280×720 帧）
数字为：24pt 静止 σr 0.171 → 0.080pt（-53%）；20pt 中距失焦组命中率 56% → 72%；
20pt 远距组（帧上 8–15px）34% → 44%。真机复测用 `--calibrate --serve` 跑会话后
`tools/plot_localaim.py` 分析 `scenes/localaim_*.csv`（含 detect_ms/quality 列）。

**边角定位与滤波手感（WP1/WP3，2026-08-17）**：贴近边角瞄准只有 3 个标记可见时
走仿射兜底（凸包护栏 1.5×，回放三点簇帧转化率 10/10 = 100%，护栏外零假阳性）；
检出不足时白点按速度衰减滑行最多 5 帧不再一丢就隐；跳变门限拦单帧跳变
（15pt 注入实测：门开偏离 0.19pt vs 门关 14.31pt）；静止 σ 不劣化
（bench 0.080pt 持平）。**滤波预设三档与单项旋钮的人话调参指南：
[docs/aim-filter-tuning.md](docs/aim-filter-tuning.md)**（`--filter-preset
stable|daily|fast` + `--dot-*` 旋钮；横扫平均误差实测：稳如三脚架 1.15pt /
日常跟手 0.66pt / 疾速响应 0.40pt）。

透明悬浮层为每个标记附带 8pt 白色底卡，保证任意桌面背景下的 ArUco 静区；
窗口点击穿透、置顶、不遮挡正常屏幕内容，ESC 退出。
手机摄像头在近距离开原分辨率画面，实际可用尺寸只会比这个更小。

首次运行需在 **系统设置 → 隐私与安全性 → 屏幕录制** 授权运行它的终端/Xcode。

## 与整体方案的对应关系

| 模块 | 本实例 | 产品化时 |
|---|---|---|
| 屏幕采集 | ScreenCaptureKit | 相同；或替换为 NDI 接收（`NDIlib_recv_*`） |
| 标记检测 | `OpenCVBridge.detectMarkers` | 相同，可换 AprilTag 提高远距离鲁棒性 |
| 坐标映射 | `OpenCVBridge.mapPointRANSAC`（冗余 8 标记 + RANSAC）+ One Euro 滤波 | 相同 |
| 标定 UI | 全屏悬浮层 8 标记自动标定 | 相同 |
| 坐标消费 | print；`--calibrate --serve --aim-cursor` 时 `CGWarpMouseCursorPosition` 绑定光标 | UDP/WebSocket 发给手机 |

## 注意

- ArUco 标记显示时**必须留白边（静区）**，贴边无法检测
- `Package.swift` 中 OpenCV 路径硬编码为 `/opt/homebrew/opt/opencv`（Apple Silicon Homebrew）
- 当前 `screenCornerMap` 是示例值，实际标定流程是：Mac 全屏显示标记 → 记录标记中心的屏幕逻辑坐标 → 填入映射表
