# 构建 · 运行 · 验证 · 排错

## 环境

```bash
brew install opencv          # OpenCV 5.x（含 aruco），路径硬编码 /opt/homebrew/opt/opencv
brew install xcodegen        # iOS 工程生成
swift build                  # Mac 端，Swift 6.x
```

权限：Mac 端首次运行需 **系统设置 → 隐私与安全性 → 屏幕录制** 授权终端/Xcode；
手机鼠标模拟（`--serve`，protocol.md §8）还需 **辅助功能** 授权（启动时自动弹窗，
未授权则 CGEvent 被系统静默丢弃）。

## Mac 端验证清单

| 步骤 | 命令 | 通过标准 |
|---|---|---|
| 离线自检 | `swift run ScreenAim --self-test` | 8 标记全检出，全量/遮挡任一角/遮挡相邻双角映射误差均 < 2pt，输出"自检通过 ✅" |
| 纯 Swift 自检 | `swift run ScreenAim --swift-self-test` | 同上（iOS 端同款检测器 + RANSAC 路径） |
| 生成标记 | `swift run ScreenAim --make-markers ./markers` | markers/ 下 8 张 PNG |
| 悬浮标定 | `swift run ScreenAim --calibrate` | 四角 + 四边中点出现标记，日志输出 FPS（含 det=xxms）与瞄准点坐标 |
| 手机联调 | `swift run ScreenAim --calibrate --serve 9100` | 中央出现配对二维码，手机连上后二维码隐藏 |
| 检测基准 | `python3 tools/make_bench_scenes.py && python3 tools/bench_detect.py 'scenes/bench20*.png'` | 命中率/σ 汇总（基准场景可再生） |
| 滤波基准 | `swift run ScreenAim --swift-seq scenes/static48_*.png` | One Euro 滤波前后静止 σ 对比 |

## iOS 端构建

```bash
cd ios && xcodegen generate     # 改了 project.yml 后重新生成
open ios/AimPhone.xcodeproj     # 选 Development Team，部署真机
```

验证要求：iPhone 12+（SE 3/16e 不支持 DockKit）+ **iOS 26+**（传输层 TLV API 门槛，ADR-011 ②；DockKit 下限 17.4 已包含）。
DockKit 行为**模拟器无法验证**；模拟器构建自动降级为空操作属预期。

## 联调实测基准（本机 1728×1117，1280 宽降采样）

- 本机采屏约 29 FPS；手机推流 15fps，720p，延迟约 100ms
- 模拟推流 60/60 帧全检出；24pt 标记抖动 σ ≈ 0.05pt；20pt 以下检不出
- 标记必须带白色静区底卡（Calibrator 已内置 8pt 白卡）

## 真机数据采集（识别算法调参用，protocol.md §10）

1. `swift run ScreenAim --calibrate --serve 9100`，手机连接（新包）
2. 摆好场景（距离/标记大小），点顶部面板的 ● 按钮采 10s（再点提前停），
   落盘 `scenes/capture_<label>_<时间戳>/`；距离/运动语义请事后补充进目录名
3. 回放调参：`swift run ScreenAim --replay scenes/capture_xxx`
   （可加 `--min-cell-gap/--thresh-c/--window/--no-refine` 覆盖检测器参数做 A/B），
   输出三方命中率（线上/离线/OpenCV 参照）、中心误差、aim σ、拒绝直方图、replay.csv
4. 场景矩阵：3 距离（屏幕占画面 ~90%/65%/40%）× 标记 {24,20,16pt} ×
   {云台静止, 手持微抖, 快速横扫} + 遮挡 2 段；每段 10s@5fps（≈50MB/段）

## 排错速查

| 症状 | 先看 |
|---|---|
| iPhone 连接一直"连接中" | 本地网络授权弹窗（设置 > AimPhone）；看门狗会自动重试 6 次 |
| 检测不到标记 | 标记太小（< 24pt 屏幕点）/ 没有静区 / 环境光直射屏幕 |
| 画面横屏翻转 | ADR-002：检查 RotationCoordinator 三个同步时机是否都在 |
| 云台按键无反应 | 真机？iOS 17.4+？看云台 pill 下的调试事件历史 |
| 屏幕条纹/过曝 | ADR-003：曝光是否被改回自动；亮度本质是 ISO 调节 |
| `swift build` 找不到 OpenCV | `brew install opencv`；Intel Mac 需改 Package.swift 路径前缀 |

## 发布流程（GitHub Release）

`release-artifacts/` 已被 .gitignore 忽略，产物不进仓库。

### macOS 端

```bash
swift build -c release        # 产物 .build/release/ScreenAim
tar -czf release-artifacts/ScreenAim-macOS-arm64.tar.gz -C .build/release ScreenAim
```

二进制动态链接 Homebrew OpenCV，用户机需先 `brew install opencv`
（路径硬编码 /opt/homebrew/opt/opencv，Apple Silicon）。

### iOS 端

```bash
xcodebuild -project ios/AimPhone.xcodeproj -scheme AimPhone \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath ios/build/AimPhone.xcarchive archive
xcodebuild -exportArchive -archivePath ios/build/AimPhone.xcarchive \
  -exportPath ios/build/ipa -exportOptionsPlist ios/build/ExportOptions.plist
cp ios/build/ipa/AimPhone.ipa release-artifacts/AimPhone-iOS.ipa
```

development 签名，team 4VF7272J66（ExportOptions.plist 已固化，仅同团队机器可复现）。

WARNING: 若 xcode-select 指向 CommandLineTools（`xcode-select -p` 显示
/Library/Developer/CommandLineTools），xcodebuild 会报 "requires Xcode"，
需前置 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
（实测 2026-08 v0.2.0 构建即此情况；不改系统 xcode-select）。

### 上传

```bash
gh release create vX.Y.Z \
  release-artifacts/AimPhone-iOS.ipa \
  release-artifacts/ScreenAim-macOS-arm64.tar.gz
```
