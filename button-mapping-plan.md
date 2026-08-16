# AimPhone 云台按键可配置化 · 详细规划

> 依据：`dockkit-button-mapping` skill 的三层套路（事件通道 → 手势识别 → 动作配置）。
> 现状基线：`GimbalManager.swift` 已有关键资产——accessoryEvents 订阅、扳机修饰键门控、
> 轮盘基线防跳变、`lastEvent` 上屏调试通道、pill 图例。**这些直接复用，不推倒重写。**

## 现状 → 目标的差距

| 维度 | 现状 | 目标 |
|---|---|---|
| 映射定义 | 硬编码（`onShutter`/`onFlip`/`onZoomDelta` 三个闭包） | 声明式绑定表，`Trigger → Action`，Codable 持久化 |
| 手势词汇 | 只有"按住修饰 + 按下沿" | 单击/双击/长按/按住/组合 + 修饰快照 |
| 图例 | pill 图标硬编码（scope/sun/qrcode/link） | 由绑定表数据驱动 |
| 用户可配 | 无 | 设置页改绑 + 学习模式捕获 + 恢复默认 |
| 事件事实 | 扳机通道仍靠 `lastEvent` 观察中 | 实测矩阵归档，id/通道确定 |

## 阶段 0：事件实测矩阵（先行，阻塞后续设计决策）

当前代码注释已标明"扳机可能走 trackingButtonEnabled 通道"未定。先固化事实：

1. 用现有 `lastEvent` 上屏 + OSLog，按 `references/flow2pro.md` 的实测矩阵模板逐键操作：
   扳机按下/松开/双击/三击/长按、快门、切换键单双击、轮盘慢转/快转/到头保持、C 键。
2. 记录每条物理操作收到的通道与载荷（`.button` id 值、pressed 翻转、toggle 事件重复率、
   轮盘 factor 范围与粒度、固件吞掉哪些手势）。
3. 产出：填好的实测矩阵表格（追加到 `references/flow2pro.md`），确定"可用键位全集"。

**验证**：真机路线走 `iphone-linked-dev` skill（devicectl 部署 + 控制台日志）。
**完成判据**：每个物理控件至少一行实测记录；扳机的上报通道有确定结论。

## 阶段 1：手势识别层（GimbalManager 内部重构）

改动集中在 `GimbalManager.swift`，对外接口不变（仍是语义化输出）：

1. 定义 `enum GimbalGesture`：`tap/doubleTap/longPress/holdStart/holdEnd/wheel(delta, modifiers)`，
   按键标识 `enum GimbalButton: Codable`（`.shutter/.flip/.trigger/.wheel/.unknown(id)`）。
2. 事件循环里嵌入识别状态机：
   - `.button(id, pressed)`：维护修饰集合（现有 `pressedButtons` 逻辑迁入）+ 长按计时
     （`Task.sleep` 350–500ms，可取消）+ 多击计数（窗口 350ms）。
   - `.cameraShutter/.cameraFlip`：无 pressed 状态，只做按下沿 + 多击窗口。
   - `.cameraZoom`：保留现有基线逻辑，输出带修饰快照的 `wheel` 手势。
3. 输出改为单一回调 `onGesture: ((GimbalGesture) -> Void)?`，替换现有三个硬编码闭包。
4. `lastEvent` 调试通道保留，同时报告识别出的手势（实测与调试都靠它）。

**风险**：单击延迟一个多击窗口才触发——扫码/连接这类动作对 350ms 延迟可接受；
若不可接受则单击即时触发、双击到来时执行"撤销+新动作"（仅对可逆动作启用）。
**完成判据**：真机上阶段 0 矩阵中的每个手势都能被正确识别并在 `lastEvent` 显示。

## 阶段 2：动作目录 + 绑定表（可配置核心）

新增 `ButtonMapStore.swift`（或并入 GimbalManager，视体量）：

1. `enum GimbalAction: Codable, CaseIterable`：起步全集 =
   `scanQRCode / toggleConnection / adjustBrightness / none`，每个 case 带 `title` + `symbol`。
2. `struct GimbalTrigger: Codable, Hashable` = 按键 × 手势 × 修饰快照。
3. `typealias ButtonMap = [GimbalTrigger: GimbalAction]`：
   - 默认表 = 现有行为（轮盘+扳机→亮度、快门+扳机→扫码、翻转+扳机→连接），保证升级后行为不变；
   - `@AppStorage("gimbalButtonMap")` 存 JSON；提供 `reset()`。
4. 路由：`onGesture` 处理器组装 Trigger 查表，switch 动作后调用 ContentView 注入的能力闭包
   （能力闭包接口基本沿用现有 `onShutter/onFlip/onZoomDelta`，改为按动作分派）。
5. pill 图例改为数据驱动：遍历绑定表生成图标列表，修饰态点亮逻辑不变。

**完成判据**：改 AppStorage 里的 JSON 即改变按键行为；默认配置与现状逐键等价（真机对比验证）。

## 阶段 3：设置页 + 学习模式

1. 入口：pill 长按或连接面板加"按键"行（遵循 `ios-camera-ui` 的 pill/玻璃规范）。
2. 设置页内容：
   - 绑定列表：每行 = Trigger 描述（"扳机按住 + 快门"）+ 动作选择器（动作目录全枚举）；
   - **学习模式**：点"录制"后 5s 内按云台按键，复用事件通道捕获 Trigger 写回——免用户理解 id；
   - 冲突检测：新绑定与已有 Trigger 相同 → 弹覆盖确认；
   - "恢复默认"按钮。
3. 触觉/视觉确认沿用现有规范（触发时图标闪烁 + light impact；轮盘跨刻度 selection 反馈）。

**完成判据**：不脱手云台完成一次"录制 → 改绑 → 触发新动作"闭环。

## 阶段 4（可选增强，按价值排期）

- 上下文分层：扫码中/未连接时同一 Trigger 映射不同动作（最低成本功能倍增，实则路由层已隐含）。
- 双击/三击绑定的 UI 开放（阶段 1 已具备识别能力）。
- 预设 profile：整套 ButtonMap 一键切换（如"配对模式"vs"瞄准模式"）。
- RPT 长按连发（TourBox 套路）——仅当未来出现"按住连调"需求时再做。

## 验证总路线

- 阶段 0/1/2 的按键行为验证全部走真机（DockKit 模拟器不可用，无配件路径保持静默降级）。
- 每阶段完成后回归：无云台启动不崩、模拟器编译通过（`#if canImport(DockKit)` 守卫保持）。
- 阶段 2 的等价性验证清单 = 阶段 0 实测矩阵 + 现有 README 的四条按键映射行为。

## 工作量估计

| 阶段 | 主要改动文件 | 规模 |
|---|---|---|
| 0 实测矩阵 | 无代码（文档产出） | 0.5 天（含真机操作） |
| 1 手势识别 | GimbalManager.swift | 1 天 + 真机调试 |
| 2 动作目录/绑定表 | 新文件 + GimbalManager + ContentView pill | 1–1.5 天 |
| 3 设置页/学习模式 | ContentView 或新 SettingsView | 1–1.5 天 |
| 4 增强 | 视项 | 按需 |
