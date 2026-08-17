# 通信协议

iPhone（AimPhone）⇄ Mac（ScreenAim）之间的全部线上格式。改任何一端前对照本文。

> **当前唯一传输协议是 §11 的 TLV 消息通道**（9100 单端口，`_aimphone._tcp`）。
> 旧手工分帧链路（9100 `[4B 长度]` 帧 + port+1 采集连接）已于 P3 拆除（ADR-011 ①），
> §1/§2/§10 保留为历史档案，仅回放旧采集数据或从 git 历史恢复旧链路时需要。

## 1. 视频帧推送（iPhone → Mac）【已移除，见 §11】

> 旧手工分帧格式（P3 前）：`[UInt32 大端帧长度][JPEG 数据]` 循环，Mac 端上限 16 MB。
> 现行等价物：TLV type 0（§11），帧内容参数不变（720p JPEG 质量 0.6 ≈15fps）。
> Mac 消费入口不变：`ScreenSampler.processJPEG(_:)`。

## 2. 服务发现（Bonjour）

- Mac 发布：`_aimphone._tcp`，服务名 `AimPhone-Mac`（`FrameServerV2.start()`，TLV 协议 §11）
- iPhone 浏览同类型，发现即自动连接；连接成功后停止浏览
- **手动断开后不再自动重连**（`suppressAutoConnect`），用户显式连接（按钮/扫码/云台翻转键）后才恢复自动发现
- 手动兜底：App 界面输入 IP/端口直连，或扫码配对

> 过渡期曾并存 `_aimphone2._tcp`（9102）区分新旧协议；P3 收敛后 TLV 直接复用
> `_aimphone._tcp` / 9100，`_aimphone2` 服务名与 9101/9102 端口均已撤除。

## 3. 二维码配对 payload

Mac 悬浮层中央显示二维码（Calibrator），内容为 JSON：

```json
{"host":"192.168.1.100","port":9100}
```

- `port` 即 TLV 服务端口（§11）；过渡期曾带 `port2` 字段（P3 已移除，
  iPhone 端仍兼容读取旧二维码的 `port2`）

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

- Mac 端：映射结果 `print` + `onAim` 回调。`--calibrate --serve` 加 `--aim-cursor` 时
  瞄准点（One Euro 滤波后的屏幕点坐标，与 Quartz 全局坐标系一致）直接
  `CGWarpMouseCursorPosition` 绑定鼠标光标，钳制在屏内；与 §8 触控点击配合即
  "手机瞄哪里点哪里"。产品化剩余方向（见根 README 对照表）：UDP/WebSocket 回传手机
- iPhone 端：本机识别结果通过 §7 `localAim` 控制帧上报 Mac（每帧不抽稀，≈15Hz；debug 对照 + Mac 端白点显示用）

## 6. 标定映射表下发（Mac → iPhone，控制信道）

手机连接建立后，Mac 立即在同一连接上反向发送一次（TLV type 1，§11；
旧链路为 `[4 字节大端长度][JSON UTF-8]`，P3 已移除）：

```json
{"type":"calib","screenW":1728.0,"screenH":1117.0,
 "markers":{"0":[36.0,36.0],"1":[1692.0,36.0],"2":[1692.0,1081.0],"3":[36.0,1081.0],
            "4":[864.0,36.0],"5":[1692.0,558.5],"6":[864.0,1081.0],"7":[36.0,558.5]},
 "filterPreset":"daily"}
```

- `markers`：定位码 id → 屏幕点坐标（左上角原点），与 Mac 端 `screenCornerMap` 同源。
  冗余 8 标记（ADR-007）：id0–3 四角、id4–7 四边中点（上/右/下/左），任取 ≥4 个即可建单应；
  条目数随 Calibrator 布局自动扩展，格式本身不变
- `filterPreset`：口语化滤波预设（WP3.4 新增可选字段，只加不删）：
  `stable` / `daily` / `fast`，iPhone 端应用到识别段滤波（`ScreenLocalizer.applyFilterPreset`）；
  旧版 iPhone 忽略该字段、保持编译期默认档；旧版 Mac 不下发时新版 iPhone 同为默认档。
  逐项参数映射见 docs/aim-filter-tuning.md
- iPhone 端 `CameraStreamer.receiveControl/handleControl` 接收并写入 `ScreenLocalizer`
- 收不到时（旧版 Mac）iPhone 用内置默认表（1728×1117 + 48pt 标记 + 24pt 边距，同为 8 项）
- 旧版 iPhone 从不读反向数据，消息滞留连接缓冲区无影响，向后兼容；
  要求恰好 4 项的中间版本 iPhone 会忽略 8 项 calib 并沿用内置默认表（与 Mac 默认参数一致）

同信道第二种消息——**配对二维码可见状态推送**（任何变化时广播给所有已连手机）：

```json
{"type":"pairingQR","visible":true}
```

## 7. 手机控制帧（iPhone → Mac）

与视频帧共用连接（TLV type 1，§11；旧链路用"长度字最高位置 1"区分控制帧，P3 已移除）：

目前唯一消息：

```json
{"type":"togglePairingQR"}
```

效果：Mac 标定层**切换**中央配对二维码的显示/隐藏（同一个按钮来回切换），
切换后 Mac 通过 §6 的 `pairingQR` 消息把真实状态推回手机，按钮高亮跟随。
下次有手机配对成功仍自动隐藏。Mac 端 `FrameServer.onControl` 分发，
iPhone 端 `CameraStreamer.toggleMacPairingQR` 发送。

第二种消息——**手机本机识别结果上报**（每帧不抽稀，≈15Hz，与 LOCALAIM 日志同节奏）：

```json
{"type":"localAim","markers":6,"detected":[0,1,2,4,5,6],"missing":[3,7],
 "x":864.0,"y":558.5,"detect_ms":12.3,"quality":"homography"}
```

- `markers`：本帧检出的定位码数量（0–8）；匹配标记 <3 且滑行预算耗尽时无 `x`/`y` 字段
  （ADR-007 后不再要求 4 角集齐，≥4 个匹配走单应；WP1 起恰好 3 个匹配走仿射兜底，
  检出不足时最多滑行 5 帧，ADR-013）
- `detected` / `missing`：检出 / 缺失的标记 ID 数组（全集 id0–7）
- `x`/`y`：帧中心映射的屏幕点坐标（左上角原点），与手机端 `localAim` 同源
- `detect_ms`：本帧检测+映射耗时（Phase 0 基线测量；旧客户端无此字段，Mac 端按 0 记录）
- `quality`：输出等级（WP1 新增可选字段，只加不删，旧端忽略）：
  `homography`（≥4 对 RANSAC 单应）/ `affine`（恰好 3 对仿射兜底，凸包护栏内）/
  `coast`（断帧滑行外推）；无 `x`/`y` 时无此字段
- 用途：Mac 端 debug 对照（两端同帧各自识别，比对输出一致性）。Mac 端 `FrameServer.onControl`
  打印，实时显示在标定层底部胶囊 debug 标签（检出不足时变黄提示「缺定位码」），
  并把 `x`/`y` 瞄准点渲染为屏幕上的白点覆盖层（无瞄准点/断连时隐藏）；
  **每条上报追加一行结构化日志**到 `scenes/localaim_<会话时间>.csv`
  （列：`timestamp,markers,ids,x,y,detect_ms,src,quality`，无瞄准点时 `x,y` 留空，
  `src` 为来源通道（TLV 链路记 `tlv`，旧链路历史数据为 `tcp`，§11）；
  `quality` 列 WP1 新增、只加不删，旧客户端上报留空），
  供离线统计识别成功率与轨迹
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
{"type":"mouseDown","button":"left"}
{"type":"mouseUp","button":"left"}
{"type":"mouseUp","button":"all"}
{"type":"mouseScroll","delta":2}
{"type":"mouseClick","button":"left"}
```

- **前置条件**：仅 `--calibrate --serve PORT`（手机推流）模式存在此链路；无参数
  仅采样模式不起帧服务，手机连不上。Mac 端还需 系统设置 > 隐私与安全性 > 辅助功能
  授权（启动时自动弹窗提示；未授权时 CGEvent 被系统静默丢弃，收到鼠标消息时打印一次性警告）
- `mouseDown` / `mouseUp`：按下/抬起分离上报（落指发 down、抬指发 up），
  `button` 为 `left` / `right` / `middle`；Mac 端 `postMouseDown/Up` 在**当前光标位置**
  分次注入，按住期间移动光标即拖拽。快速点按 = down+up 紧邻到达，效果等价完整点击
- `mouseUp` + `button:"all"`：断开兜底。iPhone 端 `disconnect()` 在发 `disconnect` 帧前
  无条件补发；Mac 端对自行跟踪的按下键集合补发 up（对未按下的键收到 up 是安全 no-op）。
  连接被动断流时 Mac 端 `FrameServer.onDisconnect` 同样补发，防止鼠标键卡死在按下态
- `mouseScroll`：`delta` 为滚轮刻度（行）增量，正 = 向上滚（与手机端手指上滑同向）；
  滚轮竖拖每 14pt 累计一格上报一次；Mac 端 `postMouseScroll` 用 `CGEvent` 滚轮事件注入
- `mouseClick`：旧协议完整点击（按下+抬起一次注入），保留给旧 iPhone 客户端；
  新版 iPhone 不再发送。Mac 端新旧消息都支持，双向向后兼容
- **信号捕获日志**：每条鼠标事件追加一行到 `scenes/mouse_<会话时间>.csv`
  （列：`timestamp,event,button,delta`，event ∈ down/up/click/scroll，
  scroll 时 button 为空、delta 为刻度增量），并实时显示在标定层底部 debug 胶囊
  （与 localAim 共用一行，≈15Hz 的 localAim 会自然刷新回来）

## 9. （保留）

按定位优化方案 §7.7 预留给 Phase 3 UDP 结果通道。

## 10. 数据采集回传（识别算法优化用）

真机无损帧采集：Mac 触发 → iPhone 录制 → 第二条 TCP 连接回传 → Mac 落盘回放。

**触发/停止**（Mac → iPhone，§6 控制信道，只加不删）：

```json
{"type":"captureStart","seconds":10,"fps":5,"label":"m24_i24"}
{"type":"captureStop"}
```

- Mac 标定层面板的 record 按钮发送（`Calibrator.captureButton`）；旧版 iPhone 忽略未知 type
- iPhone 端 `CaptureRecorder` 在 `aimphone.capture` 队列逐帧抽录：BGRA → **无损 PNG**
  （禁止重编码，回放须像素级复现检测器输入）+ `meta.jsonl` 逐帧元数据
  （seq/PTS/ISO/曝光/变焦/角速度/线上检测结果 ids+centers/aim/detect_ms）
- 到时自动停止或收到 captureStop；预估体积 >200MB 或磁盘不足会拒绝启动（状态文案提示）

**回传**（iPhone → Mac）【旧独立连接已移除，见 §11】：

> 旧格式（P3 前）：第二条 TCP 连接（端口 = 帧服务端口 + 1），
> `[4B 大端 jsonLen][json][4B 大端 binLen][bin]` × N 条记录，end 后 finalMessage 关闭。
> 现行等价物：主 TLV 连接 type 10（session/end JSON）/ type 11（帧复合 payload
> `[4B jsonLen][json][PNG]`）。落盘目录结构、session.json 双端合并、`--replay` 回放均不变。

## 11. TLV 消息通道（iOS 26 / macOS 26+，迁移主路径）

Network.framework 26+ 结构化并发 API（NetworkListener / NetworkConnection）+ 内置 TLV
分帧器。单连接承载全部流量，框架托管分帧/消息边界/长度校验/背压（`try await send`
挂起即背压），手工 `readHeader/readBody` 状态机与"长度字最高位当标志位"整体作废。

**线上格式**（网络字节序，每条消息 8 字节头）：

```
┌──────────────┬────────────────┬──────────────────┐
│ type: UInt32 │ length: UInt32 │ value: [UInt8]   │
│ 4 字节        │ 4 字节          │ length 字节       │
└──────────────┴────────────────┴──────────────────┘
```

**type 路由表**（`TLVMessageType`，ScreenAimCore 双端共享常量）：

| type | 方向 | 内容 |
|---|---|---|
| 0 | iPhone→Mac | 视频帧 JPEG（≈15fps，参数同 §1） |
| 1 | 双向 | 控制 JSON：calib↓/pairingQR↓/captureStart·Stop↓，togglePairingQR/localAim/mouse*/disconnect↑（消息 schema 与 §6/§7/§8 完全一致，仅分帧方式改变） |
| 2 | （预留） | Coder(AimMessage) 信封枚举，P3 评估启用 |
| 10 | iPhone→Mac | 采集 session/end 记录（纯 JSON，schema：session=设备型号/系统版本；end=帧数+角速度峰值） |
| 11 | iPhone→Mac | 采集帧复合 payload：`[4B 大端 jsonLen][json][PNG]`（json = meta.jsonl 一行） |

- 接收方遇未知 type 一律忽略（向后兼容机制：新版新增的 type 不应使旧端断连）
- 断开兜底语义不变：iPhone 主动断开前发 `mouseUp all` + `disconnect`（type 1），
  以 `lastMessage` 收尾保证通知帧先于 FIN（等价旧路径 finalMessage）；
  Mac 端连接终结时对按住中的鼠标键补发 up（ADR-008）
- 采集录制语义与旧 §10 一致：captureStart/Stop 触发（type 1）、无损 PNG + meta.jsonl、
  落盘 `scenes/capture_<label>_<时间戳>/` 三件套（`CaptureIngestor`）、
  中途断连按已收帧数兜底收尾、`--replay` 回放路径不变
- localAim CSV 的 `src` 列：TLV 链路记 `tlv`（旧链路历史数据为 `tcp`）
- 看门狗语义保留：5s×6 重试（`establishmentReport` 与超时竞争），
  本地网络授权弹窗期卡死问题在 Bonjour/IP 路径依然存在（§4）
- **两端必须 `TCP().noDelay(true)`**：新 API 的 `TCP()` 默认 Nagle 开启，会把 15fps 的
  小控制消息攒批成 ~200ms 一坨（真机实测 localAim 批量突发、白点阶梯滞后）
- type 2 评估结论（P3）：**不启用** Coder 信封枚举——控制消息小且低频（≤200B），
  `JSONSerialization` 现状够用，Coder 的类型安全收益不足以抵消双端信封枚举同步成本；
  type 2 继续预留，控制消息真要 schema 化时再启用

**端口与服务（P3 收敛后）**：

| 端口 | 服务 | 协议 |
|---|---|---|
| 9100（servePort） | `_aimphone._tcp` | **TLV（本节），唯一传输服务** |

（历史：过渡期曾并存 9100 旧手工分帧 + 9101 旧采集 + 9102/`_aimphone2._tcp` TLV，P3 已全部撤除）

## 12. Wi-Fi Aware 通道（已终止，待生态成熟）

P0 尖刺结论：Wi-Fi Aware 在 macOS 不可用（Xcode 26.6 SDK 全符号
`@available(macOS, unavailable)`，系统框架为空壳），Mac 无法做 WA publisher，
通道整体终止（ADR-012）。恢复条件与设计底稿见 transport-26-plan §3；
复测入口 `tools/wa-spike/run.sh`（SDK 开放 macOS 后编译通过即推翻信号）。
