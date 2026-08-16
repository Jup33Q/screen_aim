# 通信协议

iPhone（AimPhone）⇄ Mac（ScreenAim）之间的全部线上格式。改任何一端前对照本文。

## 1. 视频帧推送（iPhone → Mac）

TCP 长连接，循环发送：

```
┌────────────────────┬──────────────────────┐
│ UInt32 大端帧长度    │ JPEG 数据             │
│ 4 字节              │ length 字节           │
└────────────────────┴──────────────────────┘
```

- 帧内容：720p 相机帧，JPEG 质量 0.6，约 15fps（`CameraStreamer.frameInterval`）
- Mac 端长度上限 16 MB，越界/断流即断开（`FrameServer.readHeader`）
- Mac 消费：`ScreenSampler.processJPEG(_:)`

## 2. 服务发现（Bonjour）

- Mac 发布：`_aimphone._tcp`，服务名 `AimPhone-Mac`（`FrameServer.start()`）
- iPhone 浏览同类型，发现即自动连接；连接成功后停止浏览
- **手动断开后不再自动重连**（`suppressAutoConnect`），用户显式连接（按钮/扫码/云台翻转键）后才恢复自动发现
- 手动兜底：App 界面输入 IP/端口直连，或扫码配对

## 3. 二维码配对 payload

Mac 悬浮层中央显示二维码（Calibrator），内容为 JSON：

```json
{"host":"192.168.1.100","port":9100}
```

iPhone 端 `CameraStreamer.handleQRText` 兼容两种格式：
1. 上述 JSON（主方案）
2. 裸文本 `host:port`

IP 变化时 Mac 端每 5 秒自动重生成二维码；手机一连上，二维码卡片隐藏。

## 4. 本地网络权限陷阱

- iPhone 首次连接会弹"本地网络"授权；**弹窗期间 NWConnection 会永久卡死在
  waiting**，因此连接带 5 秒看门狗 + 最多 6 次自动重试（`startConnection`）
- 多次失败后的排查提示写在状态文案里：检查 Mac 服务是否运行 +
  设置 > AimPhone 的本地网络权限

## 5. 识别结果输出

- Mac 端：映射结果 `print` + `onAim` 回调。产品化方向（见根 README 对照表）：
  UDP/WebSocket 回传手机，或 `CGWarpMouseCursorPosition` 直接控鼠标
- iPhone 端：本机识别结果通过 §7 `localAim` 控制帧上报 Mac（2Hz，debug 对照用）

## 6. 标定映射表下发（Mac → iPhone，控制信道）

手机连接建立后，Mac 立即在同一 TCP 连接上反向发送一次：

```
[4 字节大端长度][JSON UTF-8]
```

```json
{"type":"calib","screenW":1728.0,"screenH":1117.0,
 "markers":{"0":[36.0,36.0],"1":[1692.0,36.0],"2":[1692.0,1081.0],"3":[36.0,1081.0],
            "4":[864.0,36.0],"5":[1692.0,558.5],"6":[864.0,1081.0],"7":[36.0,558.5]}}
```

- `markers`：定位码 id → 屏幕点坐标（左上角原点），与 Mac 端 `screenCornerMap` 同源。
  冗余 8 标记（ADR-007）：id0–3 四角、id4–7 四边中点（上/右/下/左），任取 ≥4 个即可建单应；
  条目数随 Calibrator 布局自动扩展，格式本身不变
- iPhone 端 `CameraStreamer.receiveControl/handleControl` 接收并写入 `ScreenLocalizer`
- 收不到时（旧版 Mac）iPhone 用内置默认表（1728×1117 + 24pt 标记 + 24pt 边距，同为 8 项）
- 旧版 iPhone 从不读反向数据，消息滞留连接缓冲区无影响，向后兼容；
  要求恰好 4 项的中间版本 iPhone 会忽略 8 项 calib 并沿用内置默认表（与 Mac 默认参数一致）

同信道第二种消息——**配对二维码可见状态推送**（任何变化时广播给所有已连手机）：

```json
{"type":"pairingQR","visible":true}
```

## 7. 手机控制帧（iPhone → Mac）

与视频帧共用连接，**长度字最高位置 1** 表示控制帧（视频帧 < 16 MB，最高位恒 0）：

```
[UInt32 大端: 0x80000000 | JSON长度][JSON UTF-8]
```

目前唯一消息：

```json
{"type":"togglePairingQR"}
```

效果：Mac 标定层**切换**中央配对二维码的显示/隐藏（同一个按钮来回切换），
切换后 Mac 通过 §6 的 `pairingQR` 消息把真实状态推回手机，按钮高亮跟随。
下次有手机配对成功仍自动隐藏。Mac 端 `FrameServer.onControl` 分发，
iPhone 端 `CameraStreamer.toggleMacPairingQR` 发送。

第二种消息——**手机本机识别结果上报**（2Hz，与 LOCALAIM 日志同节奏）：

```json
{"type":"localAim","markers":6,"detected":[0,1,2,4,5,6],"missing":[3,7],
 "x":864.0,"y":558.5,"detect_ms":12.3}
```

- `markers`：本帧检出的定位码数量（0–8）；匹配标记 <4 时无 `x`/`y` 字段（ADR-007 后
  不再要求 4 角集齐，≥4 个匹配即出瞄准点）
- `detected` / `missing`：检出 / 缺失的标记 ID 数组（全集 id0–7）
- `x`/`y`：帧中心映射的屏幕点坐标（左上角原点），与手机端 `localAim` 同源
- `detect_ms`：本帧检测+映射耗时（Phase 0 基线测量；旧客户端无此字段，Mac 端按 0 记录）
- 用途：Mac 端 debug 对照（两端同帧各自识别，比对输出一致性）。Mac 端 `FrameServer.onControl`
  打印，并实时显示在标定层底部胶囊 debug 标签（检出不足时变黄提示「缺定位码」）；
  **每条上报追加一行结构化日志**到 `scenes/localaim_<会话时间>.csv`
  （列：`timestamp,markers,ids,x,y,detect_ms,src`，无瞄准点时 `x,y` 留空，
  `src` 为来源通道，目前恒为 `tcp`），供离线统计识别成功率与轨迹
- iPhone 端 `CameraStreamer.localizeFrame` 发送；旧版 Mac 忽略未知 type/未知字段，向后兼容

第三种消息——**手机主动断开通知**：

```json
{"type":"disconnect"}
```

- 时机：iPhone 端 `CameraStreamer.disconnect()` 在取消连接前发送，随后以
  `finalMessage` 优雅关闭 TCP，保证通知帧先于 FIN 到达
- Mac 端行为：立即把配对二维码按当前 IP 重新生成并重新显示（不等 5 秒 IP 看守），
  并通过 §6 `pairingQR` 消息把可见状态推回其余已连手机
- 旧版 Mac 忽略未知 type，仅表现为断开后二维码不自动恢复，向后兼容

## 8. 横屏鼠标模拟器（iPhone → Mac，控制信道）

手机横屏时底部出现「左键 / 滚轮 / 右键」玻璃触控层（`MousePadOverlay`），
事件经 §7 同一控制信道上报：

```json
{"type":"mouseClick","button":"left"}
{"type":"mouseScroll","delta":2}
```

- `mouseClick`：`button` 为 `left` / `right` / `middle`（滚轮轻点 = 中键），
  落指即发（与真实鼠标按下一致）；Mac 端 `postMouseClick` 在**当前光标位置**点击
- `mouseScroll`：`delta` 为滚轮刻度（行）增量，正 = 向上滚（与手机端手指上滑同向）；
  滚轮竖拖每 14pt 累计一格上报一次；Mac 端 `postMouseScroll` 用 `CGEvent` 滚轮事件注入
- 两种消息都要求 Mac 端在 系统设置 > 隐私与安全性 > 辅助功能 中授权
  （否则 CGEvent 被系统静默丢弃）
- 旧版 Mac 忽略未知 type，仅表现为触控层无实际效果，向后兼容
