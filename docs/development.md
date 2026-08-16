# 构建 · 运行 · 验证 · 排错

## 环境

```bash
brew install opencv          # OpenCV 5.x（含 aruco），路径硬编码 /opt/homebrew/opt/opencv
brew install xcodegen        # iOS 工程生成
swift build                  # Mac 端，Swift 6.x
```

权限：Mac 端首次运行需 **系统设置 → 隐私与安全性 → 屏幕录制** 授权终端/Xcode。

## Mac 端验证清单

| 步骤 | 命令 | 通过标准 |
|---|---|---|
| 离线自检 | `swift run ScreenAim --self-test` | 4 标记全检出，映射误差 < 2pt，输出"自检通过 ✅" |
| 生成标记 | `swift run ScreenAim --make-markers ./markers` | markers/ 下 4 张 PNG |
| 悬浮标定 | `swift run ScreenAim --calibrate` | 四角出现标记，日志输出 FPS 与瞄准点坐标 |
| 手机联调 | `swift run ScreenAim --calibrate --serve 9100` | 中央出现配对二维码，手机连上后二维码隐藏 |

## iOS 端构建

```bash
cd ios && xcodegen generate     # 改了 project.yml 后重新生成
open ios/AimPhone.xcodeproj     # 选 Development Team，部署真机
```

验证要求：iPhone 12+（SE 3/16e 不支持 DockKit）+ iOS 17+（建议 18）。
DockKit 行为**模拟器无法验证**；模拟器构建自动降级为空操作属预期。

## 联调实测基准（本机 1728×1117，1280 宽降采样）

- 本机采屏约 29 FPS；手机推流 15fps，720p，延迟约 100ms
- 模拟推流 60/60 帧全检出；24pt 标记抖动 σ ≈ 0.05pt；20pt 以下检不出
- 标记必须带白色静区底卡（Calibrator 已内置 8pt 白卡）

## 排错速查

| 症状 | 先看 |
|---|---|
| iPhone 连接一直"连接中" | 本地网络授权弹窗（设置 > AimPhone）；看门狗会自动重试 6 次 |
| 检测不到标记 | 标记太小（< 24pt 屏幕点）/ 没有静区 / 环境光直射屏幕 |
| 画面横屏翻转 | ADR-002：检查 RotationCoordinator 三个同步时机是否都在 |
| 云台按键无反应 | 真机？iOS 17.4+？看云台 pill 下的调试事件历史 |
| 屏幕条纹/过曝 | ADR-003：曝光是否被改回自动；亮度本质是 ISO 调节 |
| `swift build` 找不到 OpenCV | `brew install opencv`；Intel Mac 需改 Package.swift 路径前缀 |
