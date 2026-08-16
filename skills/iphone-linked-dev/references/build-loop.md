# 构建-验证闭环：xcodebuild 给 Agent 用的姿势

## 构建（输出必须过滤）

`xcodebuild` 原始输出几千行，直接进上下文是灾难。两种过滤：

```bash
# 方案 1：xcpretty（brew install xcpretty），人读友好
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | xcpretty

# 方案 2：无依赖，只留错误/警告
xcodebuild -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 \
  | grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' | head -50
```

常用 destination：
- 模拟器：`-destination 'platform=iOS Simulator,name=iPhone 16 Pro'`（名字从 `xcrun simctl list devices available` 抄，必须精确；引号用直引号）
- 真机：`-destination 'platform=iOS,id=<device-identifier>'`
- 不知道 scheme：`-list` 先查：`xcodebuild -list -project MyApp.xcodeproj`（workspace 项目用 `-workspace MyApp.xcworkspace`）

## 构建产物 → 模拟器

```bash
# DerivedData 里找 .app（模拟器产物在 Debug-iphonesimulator）
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "MyApp.app" -path "*iphonesimulator*" | head -1)
xcrun simctl install booted "$APP_PATH"
xcrun simctl launch booted com.example.myapp
```

## 测试

```bash
xcodebuild test -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -resultBundlePath /tmp/TestResults.xcresult 2>&1 | grep -E 'error:|failed|passed|TEST (SUCCEEDED|FAILED)' | head -50

# 结构化读结果，只取失败项
xcrun xcresulttool get test-results summary --path /tmp/TestResults.xcresult
```

## 标准闭环（一次功能迭代的 agent 回路）

1. 改代码。
2. `xcodebuild build | 过滤` → 有 error 先修编译，**不要往下走**。
3. `simctl install + launch` → 退出码非 0 查 `log show`。
4. `simctl openurl` deep link 到目标页（或 idb/WDA 导航过去）。
5. `simctl io screenshot` → ReadMediaFile 看图，对照需求逐项核对 UI。
6. 有交互就用 idb/WDA 操作后再截图验证。
7. 跑 `xcodebuild test` 收尾。

每一步都有客观证据（退出码/截图/测试结果），不达标就回到对应步骤，不要跳步宣布完成。

## 无 Xcode 项目时

- SPM 包：`swift build` / `swift test`（不依赖模拟器）。
- Flutter：`flutter build ios --simulator` 后同样走 simctl；或 `flutter run -d <simulator-udid>`。
- React Native：`npx react-native run-ios --udid <UDID>`。
- Mob/BEAM：走 mob-beam-mobile skill 的 `mix mob.deploy` 链路。
