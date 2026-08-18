# 白点 × Liquid Glass 光标交互（iPad Magic Keyboard 式）方案

调查日期：2026-08-17。目标：Mac 端白点（`aimDot`）实现 iPad Magic Keyboard
光标与 Liquid Glass 组件的交互体验——磁吸、形态 morph、液滴融合。

## 0. 现状

- 白点 = `NSGlassEffectView`（`.clear` 玻璃 + 白 tint，14pt 圆，macOS 26+），
  挂在全屏透明覆盖层 `win`（`ignoresMouseEvents = true`，点击穿透，置顶），
  位置由 localAim 数据流驱动，60Hz 定时器做显示外推（ADR-015）。
- 顶部控制面板是**独立可点击 NSPanel**（`btnPanel`，更高 window level），
  按钮底是普通黑底 NSView 胶囊，不是玻璃视图。
- 定位码白卡是 CALayer 白底卡（ArUco 静区要求，不可玻璃化）。
- ADR-016 已有"白点 × UI 重叠检测"（panel / 白卡 rect 求交），是现成的
  磁吸目标数据源。
- `--aim-cursor` 已能把瞄准点 warp 到真实鼠标（CGWarpMouseCursorPosition）。
- 平台门槛已是 macOS 26（transport-26），Liquid Glass API 全部可用。

## 1. 可行性结论：可行，分两层

### 层级 A —— 真·液滴融合（同一进程、同一容器内）✅ 系统原生支持

macOS 26 AppKit 提供 `NSGlassEffectContainerView`：后代 `NSGlassEffectView`
在 `spacing` 指定的接近距离内会**自动合并**（SDK 头文件原文："Merges
descendants together if the views are sufficiently similar and within the
proximity specified in spacing"），并附带批量渲染性能优化。SwiftUI 侧等价物是
`GlassEffectContainer(spacing:)`。这正是 Apple 官方"液滴融合"的实现路径，
融合动画由系统渲染，无需自研 metaball。

约束：
- 只合并**同一 container 的后代**玻璃视图 → 跨窗口不合并（`btnPanel` 是
  独立窗口，直接吃不到融合；见 WP2 的取舍）。
- 只合并"足够相似"的玻璃（style/tint 接近）→ 参与融合的元素需统一为
  `.clear`/白 tint 风格。
- 融合的触发距离、动画曲线只有 `spacing` 一个旋钮，不可深度定制；若实测
  视觉不达标，备选是自绘 gooey（CAShapeLayer + blur/alpha 阈值），但会
  丢掉真玻璃折射，不推荐首选。

### 层级 B —— iPad 光标行为（磁吸 + morph + 融入任意 App 的玻璃组件）✅ 可模拟，但有边界

跨进程的**材质级真融合不可能**（各 App 各自渲染自己的玻璃，系统不暴露
合成树）。但 iPad Magic Keyboard 光标的核心体验本质是"绘制在 App 之上的
指针行为"，可以完全在我们自己的覆盖层里复刻：

1. **目标发现**：Accessibility API（`AXUIElementCopyElementAtPosition` →
   `AXRole`/`AXFrame`）拿到瞄准点下的交互元素 rect。需辅助功能权限。
2. **磁吸（magnetism）**：瞄准点进入控件磁吸半径（≈控件外扩 12–20pt）后，
   显示位置向控件中心弹性偏移——与 ADR-015 显示外推同层做，只动显示、
   不动权威瞄准点。
3. **形态 morph**：白点从 14pt 圆弹簧动画成贴合控件的圆角矩形玻璃罩
   （frame + cornerRadius 插值），视觉上"融入"组件。`cornerRadius` 未
   文档化为 animatable，用现有 60Hz 定时器手动插值最稳。
4. **功能等价**：`--aim-cursor` 模式下吸附时把 warp 点钉到控件中心，
   手机端触控点击（§8 mouseDown/Up）自然落在控件上 = iPad 光标体验闭环。

限制：
- AX 查询有延迟（轻量 App 数 ms；浏览器/Electron 大树可达 10ms+），
  需 30Hz 节流 + 结果缓存 + 速度门控（高速横扫时不吸附）。
- 部分 App AX 树缺失/不准 → 静默降级为自由圆点；建议先白名单
  （自有 panel + Finder/Safari/系统设置）验证。
- 自有 UI（btnPanel 按钮）不需要 AX——rect 本进程已知，零成本、
  100% 可靠，是第一优先级磁吸目标。

## 2. 实施计划

### WP0 尖峰验证（0.5 天，先做，否决项）

独立 demo（`tools/liquid-spike/` 或临时 SwiftPM target）验证三件事：
1. `NSGlassEffectContainerView` 内两个 `NSGlassEffectView` 相对移动时的
   融合视觉是否达标（录屏评审；重点看 `.clear` style 是否参与合并——
   官方示例多为 `.regular`，clear 合并观感需实测）。
2. `NSGlassEffectView` 的 frame/cornerRadius 60Hz 连续插值
   （14pt 圆 ↔ 200×40 圆角矩形）是否流畅、折射是否跟随。
3. `AXUIElementCopyElementAtPosition` 在本机常用 App 的命中率与延迟
   （目标：P95 < 8ms，达不到则 WP3 降级为"仅自有 UI 磁吸"）。

### WP1 自有 UI 磁吸 + morph（1–1.5 天，核心体验）

- 新模块 `AimMagnetizer`（ScreenAim 或 ScreenAimCore）：输入 = 白点显示
  位置 + 目标 rect 列表；输出 = 吸附目标（rect + 强度）或 nil。
- 目标源复用 ADR-016：btnPanel 各胶囊 / restore 胶囊的屏幕 rect
  （本进程已知，无需 AX）。
- 状态机：`free → attracting → snapped`，进出磁吸半径设滞回（进 16pt /
  出 24pt）防抖动；吸附时白点 morph 成目标 rect 内接的玻璃胶囊
  （60Hz 手动插值 frame/cornerRadius/tint 强度）。
- 与 `dotFilter` 显示外推串联：吸附态优先于匀速外推。
- 吸附瞬间 `NSHapticFeedbackManager .alignment`（滑杆已有先例）。
- CLI：`--aim-magnet`（默认 off，先灰度）。

### WP2 液滴融合（0.5–1 天，依赖 WP0-1 结论）

- 主 overlay 的 contentView 内嵌 `NSGlassEffectContainerView(spacing: N)`，
  把 `aimDot` 移入其 contentView。
- 把 1–2 个自有 overlay 元素玻璃化进同一 container 验证融合：首选
  restore 胶囊与调试 pill（不影响识别；定位码白卡**不动**——静区要求）。
- spacing 调参（建议起点 24pt）；融合只发生在白点接近这些元素时，
  其余时间白点独立渲染，性能无感。
- `btnPanel` 不迁移（它是独立可点击窗口，主 overlay 点击穿透；迁移要
  重做 hit-test 放行，收益不成比例）——panel 方向的"融合感"由 WP1 的
  morph 吸附承担，视觉已足够接近。

### WP3 任意 App 磁吸（1.5–2 天，可选扩展，依赖 WP0-3 结论）

- `AXHitTester`：辅助功能权限检查/引导 → `AXUIElementCopyElementAtPosition`
  → 角色白名单（button/checkbox/slider/textField/link…）→ AXFrame。
  30Hz 节流 + 100ms 结果缓存 + 速度门控（>400pt/s 不吸附）。
- 接入 WP1 状态机：外部 App 目标与自有 UI 目标统一排队，自有 UI 优先。
- `--aim-cursor` 联动：吸附时 warp 钉控件中心。
- App 白名单配置；AX 失败静默降级自由圆点。

### WP4 收尾（0.5 天）

- ADR（磁吸状态机 / container 选型 / btnPanel 不迁移的理由）+
  modules.md / decisions.md 更新。
- localaim CSV 增加 hover/snap 目标列，供 `tools/plot_localaim.py` 分析
  吸附命中率与手感。
- 横扫/边角回归：确认磁吸不劣化 WP1/WP3 的 σ 指标（稳如三脚架 1.15pt /
  日常跟手 0.66pt 基线）。

## 3. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| `.clear` 玻璃在 container 中不合并或观感差 | 中 | WP0-1 一票否决；改 `.regular` 低 tint 或放弃 WP2 保留 WP1 |
| cornerRadius 动画掉帧/折射撕裂 | 低 | WP0-2 验证；降 morph 动画到 30Hz 仍可读 |
| AX 延迟高/树缺失 | 中 | WP0-3 测量；WP3 整体降级为"仅自有 UI" |
| 吸附干扰瞄准精度手感 | 中 | 滞回 + 速度门控 + `--aim-magnet` 开关灰度；CSV 回归 |
| 多玻璃渲染耗电/GPU | 低 | container 自带批处理；参与融合的元素控制在 ≤5 个 |

## 4. 参考

- macOS 26 SDK `NSGlassEffectContainerView` 头文件（合并语义原文）：
  dotnet/macios wiki "AppKit macOS xcode26.0 b3"
- SwiftUI `GlassEffectContainer` 行为与 spacing 语义：
  blakecrosley.com "Liquid Glass in SwiftUI"（2026-04）；Apple 文档
- 项目内：ADR-014/015/016（滤波 / 显示外推 / 白点×UI 重叠），
  `docs/whitedot-latency-plan.md`
