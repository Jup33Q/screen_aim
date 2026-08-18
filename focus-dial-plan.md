# 对焦优化代办 Plan — 轮盘调焦 + 自动对焦提升识别率

背景结论（2026-08-17 调研）：

- 轮盘唯一 DockKit 通道是 `.cameraZoom(factor:)`（绝对倍率，语义 App 自定）；当前接线 = 扳机按住 + 轮盘 → 亮度。
- `CameraStreamer.setZoomFactor(_:)` 已写好但未接任何事件（闲置能力）。
- 对焦现状只有一行 `focusMode = .continuousAutoFocus`（`CameraStreamer.applyDeviceSettings`），无对焦区域/范围限制/锁定策略。
- 失败链：屏幕内容时刻变化 → 对比度 AF 拉风箱 → 失焦帧 → 丢标记（对应 README "20pt 中距失焦组"命中率缺口）。手机夹云台上、到屏距离物理固定 → AF 收敛后锁定是安全的。
- 数码变焦 ≤2× 在 720p preset + 12MP 传感器下只是裁切不丢有效分辨率，可直接放大标记像素（打 "20pt 远距组帧上 8–15px" 痛点）。

改代码前先读：`docs/comment-style.md`（注释规范）、`docs/decisions.md`（相关 ADR，新决策要补 ADR）。

## P0 — 对焦稳定后锁定（预期收益最大，不改交互）

- [x] `CameraStreamer` 新增 `FocusController`（或内联状态机）：启动 continuousAutoFocus → 稳定判定 → `setFocusModeLocked(lensPosition:)` 锁定 → 恶化/手动干预时解锁重 AF（2026-08-18 实施：内联两态状态机，ADR-018）
- [x] 稳定判定信号（二选一或并用）：本机识别连续 ~1s 检出 ≥6/8 标记（`localMarkerCount` 现成）；KVO `isAdjustingFocus == false` 持续稳定（实施：检出数为主 + 锁定决策点瞬读 isAdjustingFocus，不做持续 KVO）
- [x] 解锁触发：连续 N 帧检出 < 4 标记（N=10）；~~轮盘对焦微调；点按对焦（P1.5）~~；前后摄切换（`flipCamera` 走 `applyDeviceSettings` 天然重置）；`requestRefocus()` 手动干预入口已预留（本批次不接事件）
- [x] `applyDeviceSettings` 增补：`focusPointOfInterest = (0.5, 0.5)`（帧中心即瞄准点，查 `isFocusPointOfInterestSupported`）、`autoFocusRangeRestriction = .near`（云台到屏 20–80cm）
- [x] 前置检查：`isFocusModeSupported(.locked)` / `isLockingFocusWithCustomLensPositionSupported`，不支持时静默降级保持现状
- [ ] **真机验证**：`--calibrate --serve` 会话对比 20pt 失焦组命中率（基线 72%）与瞄准点 σ；`tools/plot_localaim.py` 分析 `scenes/localaim_*.csv`

## P1 — 轮盘手动对焦微调 + 对焦状态可见

> 执行状态（2026-08-18）：轮盘目标已经用户确认为**数码变焦**而非对焦微调——
> 变焦双输入（二指手势 + 轮盘）已实施（ADR-019），含跨 0.25× 刻度触觉与 >1× 倍率指示。
> 下列对焦微调条目暂缓：`nudgeFocus` 未写，轮盘不加目标切换态；`requestRefocus()`
> 解锁入口已在 P0 预留。

- [ ] `CameraStreamer` 新增 `nudgeFocus(delta:)`：KVO 读当前 `lensPosition` 为基线，±步进微调（lensPosition 非线性且机型相关，禁止硬编码距离）
- [x] 轮盘目标决策：~~扳机+轮盘从亮度换成对焦微调，或加"轮盘目标"循环切换态~~ → 已确认轮盘 = 数码变焦（ADR-019），亮度留太阳滑杆
- [ ] `GimbalManager` 事件层不动，只改 ContentView 注入的闭包路由（变焦路由已按此落地）
- [x] 视觉/触觉确认（变焦部分）：>1× 倍率指示 pill + 跨刻度 `UISelectionFeedbackGenerator`；对焦图标 + lensPosition 读数随对焦微调一起暂缓
- [ ] `isSmoothAutoFocusEnabled = true`（配合锁定策略，收敛慢的代价被覆盖）

## P1.5 — 点按对焦（原生相机语义，Liquid Glass 风格）

- [ ] `CameraPreview` 暴露预览层坐标转换：`AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`（UIViewRepresentable Coordinator 持有 PreviewView 弱引用，ContentView 只传点击点）
- [ ] `CameraStreamer` 新增 `tapToFocus(at devicePoint:)`：`isFocusPointOfInterestSupported` 前置检查 → `focusPointOfInterest = point` + `focusMode = .autoFocus`（单次 AF 到点）；曝光不动（ADR-003 手动曝光 1/120s，不挂 exposurePointOfInterest）
- [ ] 与 P0 锁定策略联动：点按 = 手动干预 → 解锁 → 到点 AF → 收敛后按 P0 稳定判定重新锁定；点按同时复位 `autoFocusRangeRestriction = .near` 保留
- [ ] 手势接线：相机预览层加 `SpatialTapGesture`；横屏时 MousePadOverlay 只占底部左右键/滚轮区（22%×19% / 14%×34%），其余画面可点；扫码中（ScanOverlay）禁用点按对焦
- [ ] 对焦框 UI（与原生相机一致 + Liquid Glass）：黄色（系统黄）四角括号方框，点击处弹出 → 缩放收敛动画 → AF 收敛或 ~1.5s 后淡出；框体容器走 `glassRounded` 封装，禁止引入第二种玻璃实现
- [ ] 触觉确认：落指 `UIImpactFeedbackGenerator(.light)`（遵守 skill DON'T：隐形映射禁止）
- [ ] 前置降级：设备不支持点按对焦（如部分前摄）时手势静默不挂，UI 无入口

## P2 — 识别反馈闭环重对焦（看 P0 实测数据再决定）

- [ ] 控制协议加 `{"type":"refocus"}`（TLV type 1，只加不删，protocol.md §11）：Mac 检测失焦特征持续丢失 → 下发 → iPhone 中心点重 AF
- [ ] `CameraStreamer.handleControl` 加 `case "refocus"` → 调 P0 的解锁重 AF 路径
- [ ] CSV 只加不删：`lensPosition` / `isAdjustingFocus` 列进 `scenes/localaim_*.csv`，离线归因"丢标记是否失焦所致"

## 验收与约束

- DockKit 与对焦行为只能真机验证（iPhone 12+ / iOS 17+ / 实体云台），模拟器全路径静默降级
- 协议与 CSV 变更遵守"只加不删"（ADR-009 / protocol.md）
- 每阶段完成后更新 README 标记实测表与 docs/decisions.md（新 ADR）
