# 模拟器路线：xcrun simctl 速查

`booted` 关键字指当前已启动的模拟器；多模拟器并行时用 UDID 替代。`xcrun simctl list devices available` 列全部可用设备与 UDID。

## 生命周期

```bash
xcrun simctl boot <UDID或名称>          # 启动（名称需精确，如 "iPhone 16 Pro"）
open -a Simulator                        # 让窗口可见（boot 本身不开窗口）
xcrun simctl shutdown <UDID> | shutdown all
xcrun simctl erase <UDID>                # 恢复出厂，测试前拿干净环境
xcrun simctl create <名字> com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-18-0
xcrun simctl list devices | grep Booted  # 找当前 booted 的 UDID
```

## App 管理

```bash
xcrun simctl install booted /path/to/YourApp.app   # 注意是 .app（模拟器构建产物），不是 .ipa
xcrun simctl launch booted com.example.app         # 退出码非 0 = 启动即崩溃，先查这个
xcrun simctl terminate booted com.example.app
xcrun simctl uninstall booted com.example.app
xcrun simctl get_app_container booted com.example.app data   # 拿沙盒数据目录，可直接读写文件布置测试数据
```

## 观察：截图 / 录屏 / 日志

```bash
xcrun simctl io booted screenshot shot.png
xcrun simctl io booted recordVideo demo.mp4        # Ctrl-C 或 kill 结束；agent 里用 timeout 包一层
xcrun simctl spawn booted log stream --level debug --predicate 'process == "YourApp"'
```

截图后立即用 ReadMediaFile 看，不要连环截十几张——一张一决策。

## 状态布置（测试前置）

```bash
xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --wifiBars 3
xcrun simctl status_bar booted clear               # 测完必须清
xcrun simctl location booted set 37.334606,-122.009102
xcrun simctl location booted clear
xcrun simctl privacy booted grant all com.example.app     # 免弹权限框；也可 grant photos/camera/location
xcrun simctl ui booted appearance dark                    # light/dark 切换验证
xcrun simctl openurl booted "myapp://products/42"         # deep link 直达，也支持 https 触发 Universal Link
```

## 推送通知

```bash
cat > push.json <<'EOF'
{"aps": {"alert": {"title": "新消息", "body": "测试"}, "badge": 1, "sound": "default"}}
EOF
xcrun simctl push booted com.example.app push.json
```

## 剪贴板互通（Mac ↔ 模拟器）

```bash
xcrun simctl pbcopy booted < text.txt     # Mac → 模拟器
xcrun simctl pbpaste booted               # 模拟器 → Mac（stdout）
```

## 常见坑

- `install` 报架构错误 → .app 是真机构建（arm64-device），模拟器要 `xcodebuild -destination 'platform=iOS Simulator,...'` 的产物。
- `launch` 返回码非 0 或秒退 → `xcrun simctl spawn booted log show --last 2m --predicate 'process == "YourApp"'` 看崩溃原因。
- 设备名含空格/括号 → 用 UDID 最稳；名称必须和 `list devices` 输出**完全一致**。
- simctl **没有 tap/swipe/type** 能力 → UI 交互走 references/ui-automation.md。
