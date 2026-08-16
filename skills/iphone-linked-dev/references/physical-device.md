# 真机路线：devicectl + 配对 + 签名

## 前置条件（一次性，需用户手动）

1. iPhone 开「设置 → 隐私与安全性 → 开发者模式」，重启后确认开启。
2. USB（或同一网络）连 Mac，iPhone 上点「信任此电脑」。
3. Xcode 里登录 Apple ID（免费账号即可，签名证书 7 天过期需重签）。
4. `xcrun devicectl list devices` 能看到设备（`available` 状态）。

## devicectl 速查（Xcode 15+，真机版 simctl）

```bash
xcrun devicectl list devices                                   # 发现设备与 identifier
xcrun devicectl device install app --device <id> /path/YourApp.app
xcrun devicectl device process launch --device <id> com.example.app
xcrun devicectl device info apps --device <id> --json-output /tmp/apps.json --quiet   # 列已装 App
xcrun devicectl device info processes --device <id>           # 列进程（拿 PID）
xcrun devicectl device copy to --device <id> --source local.txt --destination ...     # 传文件进沙盒
```

**Xcode 26 坑**：`device process terminate` 不再接受 bundle id，必须先 `info processes` 解析出 PID，再：

```bash
xcrun devicectl device process terminate --device <id> --pid <PID>
```

**日志/崩溃**：

```bash
xcrun devicectl device console --device <id> --process YourApp    # 实时日志
# 崩溃报告在 iPhone「设置 → 隐私与安全性 → 分析与改进 → 分析数据」，或 Xcode → Devices and Simulators → Open Recent Logs
```

## 真机 UI 自动化：只有 WDA 一条路

idb 对真机的 UI 操作支持不稳定；现实方案是 WebDriverAgent 部署到真机：

1. WDA 必须用**有效开发者签名**构建到真机（`xcodebuild -destination 'platform=iOS,id=<device-id>' test`），设备上出现 "WebDriverAgentRunner" 应用。
2. 真机 WDA 端口转发：`iproxy 8100 8100 <udid>`（`brew install libimobiledevice` 自带 iproxy），之后同样 `curl http://127.0.0.1:8100/status`。
3. HTTP 接口与模拟器一致（见 ui-automation.md 路线 B）。
4. 免费账号 7 天证书过期 → WDA 打不开，需重新 build。

## 真机 vs 模拟器决策

| 场景 | 必须真机 |
|---|---|
| 相机/扫码、ARKit、蓝牙/NFC 外设 | ✅ |
| APNs 生产推送、推送证书 | ✅ |
| 性能/发热/真机 GPU 渲染 | ✅ |
| Apple Pay、HealthKit、通话中断 | ✅ |
| 普通 UI 验证、逻辑测试、截图 | ❌ 用模拟器 |

真机回路比模拟器慢且多故障点（信任、签名、掉线），能模拟器就别真机。
