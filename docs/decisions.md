# 设计决策记录（ADR 精简版）

每条 = 决策 + 原因 + 推翻它之前要满足的条件。按时间倒序。

## ADR-012 Wi-Fi Aware 通道终止：macOS SDK 层不可用（P0 尖刺结论）

- **决策**（2026-08-17 P0 尖刺）：ADR-011 之③（WA 升首选通道）**终止**。
  传输主路径降级为 **TLV + Bonjour**（`_aimphone2._tcp` 过渡期 + 9100 单端口收敛），
  扫码/手工 IP 永久兜底不变；WA 归档"待生态成熟"。TLV 部分（ADR-011 ①②④）不受影响。
- **原因**（三条独立证据，复现脚本 `tools/wa-spike/`）：
  ① Xcode 26.6 SDK 中 `WiFiAware.framework` 全部公开符号（`WACapabilities` /
  `WAPublishableService` / `WASubscribableService` 等 29 处）标注
  `@available(macOS, unavailable)`（iOS 26.0+ 可用，macCatalyst 亦不可用）——
  Mac 端代码**编译期**即无法引用，包壳 .app 也救不了；
  ② macOS 26 Network.framework 接口只有 `NWError.wifiAware` 错误码，没有
  `.wifiAware` 端点描述符与 `NWParameters.wifiAware` 选项——Mac 做不了 WA listener/publisher；
  ③ 运行系统（macOS 26.6.1）上 `/System/Library/Frameworks/WiFiAware.framework`
  是无二进制的空壳（仅 Resources + 签名）。
  注：skills/wifi-aware-pairing 所引"macOS 26.0 支持"（论坛 827887）与 SDK 事实矛盾，以 SDK 为准。
- **推翻条件**：未来 Xcode/macOS SDK 将 WiFiAware 开放给 macOS 原生进程
  （重跑 `tools/wa-spike/run.sh` 编译通过即信号），届时按 transport-26-plan §3 原设计恢复。

## ADR-011 全 26+ 部署前提下传输层四项复审决策

- **决策**（2026-08-17 传输方案复审，详见 docs/transport-26-plan.md §4）：
  ① V2（TLV）真机回归通过后**拆除 9100 手工分帧服务与 iPhone 旧传输实现**——项目
  "只加不删"兼容文化（protocol.md §6/§7）的首次例外，过渡期双服务并行一个版本周期；
  ② iPhone 部署目标升 26.0，删除全部 `if #available` 双栈（DockKit 下限 17 仍满足）；
  ③ Wi-Fi Aware 由"第三通道"升为**首选通道**，Bonjour 降备用，扫码/手工 IP 永久兜底；
  ④ 采集回传并入主 TLV 连接（type 10/11），撤销独立端口；端口收敛为 9100 单端口。
- **原因**：新部署前提（目标机全部 iOS 26/macOS 26+）抽掉了原两方案保守设计的地基
  （现场无 <26 客户端）；用户明确要求传输内容最大化移交 Network.framework / Wi-Fi Aware。
  WA 首选可同时兑现无路由器直连、免本地网络授权弹窗、datapath 强制加密三项收益。
- **推翻条件**：现场出现无法升级 26 的设备（恢复旧链路，git 历史可完整回滚）；
  P0 尖刺证明 Mac 包壳 .app 无法发布 WA 服务（WA 降级，TLV+Bonjour 主路径照常）；
  采集回传与视频流单连接争用被实测证实（退回独立端口，TLV 栈不变）。

## ADR-010 默认标记尺寸 24pt → 48pt

- **决策**：`Calibrator` 默认 `markerSize` 与 iPhone 内置默认映射表同步改为 48pt
  （`--marker-size 24` 可调回，顶部面板滑杆也可实时调）。
- **原因**：24pt 是 1280 宽降采样**本机采屏**的实测可靠下限，但手机远距离实拍
  （屏幕占画面比例小）边中点标记掉检严重，真机验证 48pt 检出 >6/8。
  代价是屏幕占位变大，由滑杆/参数兜底。
- **推翻条件**：远距离识别鲁棒性提升（Vision/DataMatrix 通道切主，见
  docs/positioning-optimization-plan.md）后重新评估默认值。

## ADR-009 localAim 上报从抽稀改为每帧全量（≈15Hz）

- **决策**：iPhone 本机识别结果不再 1/5 抽稀（原 ≈2–4Hz），每帧识别每帧上报。
- **原因**：Mac 端白点覆盖层与 debug 对照的流畅度依赖上报频率，2Hz 下白点跳动
  明显；控制帧体积小（<200B），相对 15fps JPEG 视频流带宽占比可忽略。
  光标跟随（--aim-cursor）走 Mac 侧视频帧识别，不依赖本上报。
- **推翻条件**：控制信道与视频帧同一 TCP 连接，若上报被证实挤占视频带宽
  （延迟/卡顿回归），改回抽稀或白点改由 Mac 侧识别直接驱动。

## ADR-008 鼠标键按下状态 Mac 侧跟踪 + 断连双路兜底补发 up

- **决策**：Mac 端 `Calibrator` 维护 `pressedMouseButtons` 集合；iPhone 主动断开前
  补发 `mouseUp button:"all"` 兜底帧；Mac 连接被动断开（`FrameServer.onDisconnect`）
  再对残余按键补发 up（对未按下的键收到 up 是安全 no-op）。
- **原因**：按住中时断连（杀 App/断网/关机）真实鼠标键会卡死在按下态，表现为
  整屏拖拽/选中失控且用户难归因；网络层不保证兜底帧必达，故收发两端各补一道。
- **推翻条件**：改用系统级 HID 设备方案（驱动断开自动释放按键），或协议层引入
  心跳租约自动失效机制。

## ADR-007 冗余 8 标记 + RANSAC/最小二乘单应

- **决策**：屏幕四角 + 四边中点共 8 个定位码（id0–7，Calibrator 自动布局），
  检出与映射表匹配 ≥4 对即求解单应。Mac 端 `cv::findHomography(RANSAC, 3.0)`；
  iPhone 纯 Swift 端 `Homography(ransacSrc:dst:)`（随机抽 4 点 DLT + 内点集
  Accelerate dsyev_ 最小二乘精化）。
- **原因**：旧方案要求 4 角恰好集齐，缺一即整帧无输出，单帧掉检/手指遮挡是常态；
  冗余标记把"帧级命中率"变成"系统级可用率"，对本场景收益大于换字典
  （docs/positioning-optimization-plan.md §1.2）。
- **推翻条件**：8 标记对屏幕 UI 遮挡被确认不可接受，或 Vision/DataMatrix 通道
  切主后标记布局整体重设计。

## ADR-006 太阳按钮用单一 DragGesture 状态机，不用 Tap/LongPress 组合

- **决策**：落指起计时 0.35s，按住即激活亮度条，竖拖调节，短按收起；全部在一个
  DragGesture 里完成。
- **原因**：SwiftUI 的 TapGesture 与 LongPressGesture 叠加存在手势竞争，
  拖动中误触长按、松手时机不可靠。单一手势 + 显式状态（pressActive /
  pressActivated / pressMoved）行为完全确定。
- **推翻条件**：SwiftUI 手势系统修复竞争问题，或交互模型本身改版。

## ADR-005 DockKit 按键全部"扳机门控"

- **决策**：轮盘/快门/翻转键只在扳机（`.button`）按住时生效；轮盘值转增量，
  基线始终更新防止跳变。
- **原因**：不门控时，直接转轮盘云台机械臂会跟随运动，与 App 功能打架；
  按住扳机恰好是云台自身的机械锁定动作，语义天然吻合"功能修饰键"。
- **推翻条件**：目标云台固件改变扳机语义，或找到不依赖扳机的无冲突映射。

## ADR-004 主动关闭 DockKit 人物追踪

- **决策**：docked 即 `setSystemTrackingEnabled(false)`，退出/退后台/undock 显式恢复。
- **原因**：本 App 瞄准的是屏幕不是人，系统追踪会让云台跟着人转，破坏瞄准。
  该设置不持久，但按 DockKit 规范仍显式恢复。
- **推翻条件**：产品形态变为需要追踪。

## ADR-003 相机手动曝光 1/120s + 低 ISO

- **决策**：`applyDeviceSettings` 锁定 1/120s，ISO 取 minISO×1.5 起步；
  "亮度调节"实际调的是 ISO（minISO → minISO×10），快门不变。
- **原因**：拍屏幕必须压住刷新条纹；屏幕本身发白，自动曝光会过曝。
  README 早期写 1/60s，实现已改 1/120s，条纹抑制更好。
- **推翻条件**：换高刷新/无 PWM 屏幕目标场景，或改用硬件 ND。

## ADR-002 预览旋转交给 RotationCoordinator，不手动监听设备方向

- **决策**：`AVCaptureDevice.RotationCoordinator`（iOS 17+）+ KVO，
  且有三个缺一不可的同步时机（角度变化 / session startRunning /
  didMoveToWindow）。
- **原因**：冷启动手机固定在云台上时没有方向变化事件，UIDevice 方向在启动
  瞬间不可靠，手动映射会导致横屏画面翻转。RotationCoordinator 以窗口场景
  为准且自带正确初始值。
- **推翻条件**：最低系统版本降到 iOS 17 以下（需回退方案并重测冷启动横屏）。

## ADR-001 Mac 端识别（路线 B），手机端零识别逻辑

- **决策**：手机只采集 + JPEG 推流，ArUco 检测与 homography 全部在 Mac。
- **原因**：手机端零第三方依赖（纯 AVFoundation + Network），算力/发热友好；
  Mac 端 OpenCV 生态成熟，迭代快。
- **代价**：依赖局域网，延迟约 100ms。
- **推翻条件**：需要脱机/无 Mac 使用，或延迟敏感场景。
