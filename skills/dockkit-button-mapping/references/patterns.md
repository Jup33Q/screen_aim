# 按键映射设计模式详解

## 目录

- 手势识别器代码骨架（事件 → 语义手势）
- 动作目录与绑定表（Codable 配置模型）
- 学习模式（捕获 Trigger）
- 反馈设计（HUD 图例 / 触觉 / 冲突提示）
- 业界参照速查（Stream Deck / TourBox / Insta360 / 相机 Fn）

## 手势识别器代码骨架

原则：原始 `accessoryEvents` 只进不出，识别器输出语义手势枚举，路由层只消费手势。

```swift
/// 语义手势：路由层只面对这个枚举
enum GimbalGesture {
    case tap(Button)            // 单击（含 toggle 事件按下沿）
    case doubleTap(Button)
    case longPress(Button)      // 仅 .button 通道精确可用
    case holdStart(Button) / holdEnd(Button)
    case wheel(delta: Double, modifiers: Set<Button>)
}

/// 识别器状态（每按键一份）
struct ButtonState {
    var isDown = false
    var downTime: Date?
    var tapCount = 0
    var lastTapTime: Date?
    var longPressFired = false
}
```

关键参数与判定：

- 多击窗口 300–400ms；单击动作延迟一个窗口期等双击（或单击即时触发、双击到来时撤销——撤销成本高的动作选前者）。
- 长按阈值 350–500ms，用 `Task.sleep` + 取消实现；触发后置 `longPressFired`，松开时不再算 tap。
- 修饰键不进多击判定：`.button pressed` 只更新修饰集合，手势期由"修饰快照 + 主键手势"组成 Trigger。
- 轮盘基线：`lastFactor` 无论修饰状态始终更新，只按修饰状态决定是否派发——防跳变。

## 动作目录与绑定表

```swift
/// 声明式动作目录：可绑定动作的全集，UI 与执行共用
enum GimbalAction: Codable, CaseIterable, Identifiable {
    case scanQRCode            // 扫码配对 / 取消
    case toggleConnection      // 连接 / 断开 Mac
    case adjustBrightness      // 轮盘目标：亮度（连续量动作）
    case none                  // 显式禁用

    var title: String { ... }          // 设置页显示名
    var symbol: String { ... }         // SF Symbol，HUD 图例共用
}

/// Trigger = 按键 × 手势 × 修饰快照
struct GimbalTrigger: Codable, Hashable {
    var button: Button        // .shutter / .flip / .trigger(id:) / .wheel
    var gesture: GestureKind  // .tap / .doubleTap / .hold
    var modifiers: Set<Button> // 修饰键按住状态
}

/// 绑定表：Codable → AppStorage(JSON) 持久化；提供 default 工厂 + reset()
typealias ButtonMap = [GimbalTrigger: GimbalAction]
```

执行侧：识别器出手势 → 组装 Trigger → 查表 → switch 动作调用 ContentView 注入的能力闭包。**动作目录枚举值即能力清单**：新增 App 能力 = 加一个 case + 一个执行分支，UI 自动可配。

## 学习模式（捕获 Trigger）

设置页"点击后按云台按键"的实现：复用调试用的 `lastEvent` 通道——进入 capture 态后，识别器把下一条原始事件（及其修饰快照）直接作为 Trigger 写回绑定表。免用户理解 button id，同时天然兼容不同厂商硬件的 id 差异。

## 反馈设计

- **HUD 图例**：修饰键图标（按住高亮）+ 当前修饰态下可用的功能图标列表，数据驱动自绑定表（不是硬编码图标列表）。
- **触发确认**：动作执行瞬间图标闪烁 + `UIImpactFeedbackGenerator(.light)`；连续量动作每跨刻度 `UISelectionFeedbackGenerator`。
- **冲突提示**：同 Trigger 复绑时设置页弹覆盖确认。
- **禁用态**：动作当前不可用（如未连接时的"断开"）图标置灰而不是隐藏——保持图例位置稳定。

## 业界参照速查

| 产品 | 可借鉴的套路 |
|---|---|
| Stream Deck (+ Insta360 Link 插件) | 动作拖放到键位；动作带参数（"变焦 +0.1"）；预设位一键保存/调用整套状态；多页面板 |
| TourBox | 按键组合映射扩键位；RPT 长按连发开关；按前台 App 自动切换预设；HUD 实时导览图 |
| Insta360 App（云台设置） | 拨轮功能二选一（变焦/手动对焦）；速度/方向档位化（快中慢）；摇杆反向开关 |
| 相机 Fn 自定义键 | 固定键位 × 动作目录单选；菜单里"按住预览功能"提示 |
| Flow 2 Pro 固件 | 单击/双击/三击/长按/单击后长按的完整手势词汇；组合键（扳机+快门 3s=重置蓝牙）；上下文分层（拍摄页/播放页/首页同键不同功能） |
