---
name: dockkit-button-mapping
description: DockKit 云台/支架硬件按键的自定义功能配置设计指南。当用户要为 DockKit 配件按键（扳机/快门键/翻转键/智控轮盘/自定义 button id）设计或实现可配置的功能映射、扩展按键手势（单击/双击/三击/长按/按住/组合键/修饰键）、做按键映射设置 UI 或预设切换、决定 accessoryEvents 事件如何路由到 App 动作，或提到 云台按键映射 / 自定义按键 / 按键手势 / 修饰键 / 按键配置 / button mapping / Stream Deck 式动作目录 时使用。适用于 Insta360 Flow 2 Pro / Flow Pro 等 DockKit 认证硬件，iOS 17.4+。
---

# DockKit 硬件按键自定义配置

DockKit 只给 App 一条窄事件通道（`accessoryEvents`，iOS 17.4+），"自定义按键"的本质是：**在 App 侧把原始事件扩展成手势词汇，再路由到可配置的动作**。本 skill 提供三层套路：事件通道 → 手势识别 → 动作配置。

## 先认清通道能力（决定什么能做）

| 事件 | 载荷 | 能做的语义 |
|---|---|---|
| `.cameraShutter` / `.cameraFlip` | 无（toggle 事件） | 只能做"按一下触发"——无 pressed 状态，**做不了按住/松开** |
| `.cameraZoom(factor:)` | 相对变焦倍率 | 连续量输入；Apple 明确"handle the factor as you please"，语义完全由 App 定（变焦/亮度/音量/滚动…） |
| `.button(id:pressed:)` | id + 按下/松开 | **唯一能做按住语义的通道**：修饰键、press-and-hold、长按计时都靠它 |
| `accessoryStateChanges.trackingButtonEnabled` | Bool | 扳机可能走这个通道上报（追踪键），必须同时监听 |

两条铁律：

1. **固件先消化一轮**：很多按键行为在云台固件内完成（Flow 2 Pro：双击扳机=回中、三击=翻转、长按=锁轴），App 只能拿到 DockKit 透传的子集。**拿到什么必须真机实测**——把每条事件描述上屏 + 写日志，逐键按一遍建实测矩阵，不要按厂商按键手册假设。
2. **原生行为是参照系**：iOS 原相机对 shutter/flip/zoom 有默认语义（拍照/切前后摄/变焦），Flow 2 Pro 的 `.button` 单击=开始/停止追踪。自定义映射要么兼容用户已形成的肌肉记忆，要么明确覆盖。

## 手势词汇扩展（1 个物理键 → N 个功能）

按实现成本排序，全部在 App 侧状态机实现：

1. **修饰键 / 功能层（modifier / chord）**——按住扳机（`.button pressed=true`）期间其他事件走第二套映射。硬件协同红利：Flow 2 Pro 按住扳机时机械臂锁定，功能层操作不会和云台运动打架。
2. **连续量重定向**——轮盘 `cameraZoom` 绝对倍率转增量（记基线、始终更新防跳变），按需路由到不同目标参数。
3. **多击（multi-tap）**——单击/双击/三击，300–400ms 窗口；toggle 事件也能做，但只有"按下沿"可用。
4. **长按 / 按住**——仅 `.button` 通道可做精确按住语义；toggle 事件只能估长按。
5. **组合键**——两键同按（厂商已占用扳机+快门 3s=重置蓝牙，避开）。
6. **上下文分层**——App 状态（连接中/扫码中/空闲）× 按键 = 不同动作，最低成本的功能倍增器。

手势识别器的标准形态：原始事件进 → 输出语义化手势枚举（如 `.tap(.shutter)` / `.hold(.trigger)` / `.wheel(delta, modifier: .trigger)`），路由层只消费手势不碰原始事件。代码骨架见 [references/patterns.md](references/patterns.md)。

## 动作配置系统（可配置化的常用套路）

业界参照：Stream Deck（动作拖放到键位 + 参数化 + 预设位）、TourBox（组合键映射 + RPT 长按连发 + 按 App 自动切预设）、Insta360 App（拨轮功能二选一：变焦/手动对焦；环拍速度/方向档位）、相机 Fn 自定义键（动作目录里挑一个绑定）。

最小可用配置系统四件套：

1. **动作目录（action catalog）**：声明式枚举 + 关联值参数（`case adjustBrightness(step: Float)`、`case connectMac`），每个动作带显示名和 SF Symbol——UI 图例和设置页共用。
2. **绑定表**：`[Trigger: Action]`，`Trigger = 按键 × 手势 × 修饰状态`；Codable 持久化（AppStorage/JSON），带默认值和"恢复默认"。
3. **学习模式（capture）**：设置页点"录制"→ 用户按物理键 → 捕获最近一条事件作为 Trigger，免去用户理解按键 id。
4. **可视化反馈**：HUD/pill 实时图例（修饰键按住时点亮可用功能）、动作触发瞬间的触觉 + 图标闪烁确认。

进阶：预设 profile（整套映射一键切换）、冲突检测（同 Trigger 复绑提示覆盖）、RPT 长按连发。详见 [references/patterns.md](references/patterns.md)。

## 硬件按键事实表

Flow 2 Pro 物理控件、固件占用行为、DockKit 通道对应关系、组合键占用清单：见 [references/flow2pro.md](references/flow2pro.md)。换其他 DockKit 硬件时按同格式建表，先实测再设计。

## DON'T 清单

- ❌ 假设 toggle 事件有 pressed 状态 → shutter/flip 做不了按住，修饰键必须落在 `.button` 通道上。
- ❌ 轮盘直接用绝对 factor 当目标值 → 转增量并持续更新基线，否则每次接入/切目标都跳变。
- ❌ 按键逻辑写死在事件循环里 → 手势识别与动作路由分层，否则加一种手势改三处。
- ❌ 无视觉/触觉确认的隐形映射 → 物理键没有屏幕 tooltip，每次触发必须可感知。
- ❌ 模拟器上验证按键逻辑 → DockKit 仅真机 + 实体云台；无配件时全路径静默降级。
- ❌ 占用厂商组合键（扳机+快门=重置蓝牙）和系统追踪键语义而不告知用户。

## 与现有 skill 协同

- **dockkit-gimbal**：accessoryEvents API 细节、速率/坐标系坑、L0–L4 接入分级。
- **ios-camera-ui**：按键图例 pill、状态反馈的界面规范。
- **iphone-linked-dev**：真机部署 + 日志验证闭环（按键实测矩阵的执行手段）。
