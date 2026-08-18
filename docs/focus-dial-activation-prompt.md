# 对焦优化 · kimi cli 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 方案全文（背景结论、失败链分析、验收门槛）见 focus-dial-plan.md（仓库根目录）。

## 进度（2026-08-18）

- ~~第一批 P0 对焦锁定~~：已完成（ADR-018，commit 822dc16），真机部署 + 会话冒烟通过，
  正式 plot_localaim 命中率/σ 对照待补
- ~~变焦双输入~~（原计划外插队，落掉 P1 的轮盘目标决策）：已完成（ADR-019，commit f8b8ae0），
  二指手势 1×–3× + 0.1× 磁滞吸附 + 轻冲击触觉；轮盘 = 变焦（扳机门控不变）
- **下一步 = P1.5 点按对焦**（下方提示词直接发）
- P1 轮盘对焦微调：暂缓（轮盘已被变焦占用，要做需先定输入通道）
- P2 refocus 协议：暂缓不动
- 新增 ADR 编号以 docs/decisions.md 实际最大编号为准顺延（当前最新 ADR-019，预计从 ADR-020 起）

---

## 下一批提示词（P1.5 · 点按对焦 + 原生相机对焦框 UI）

```text
# 任务：ScreenAim 对焦优化 第二批（P1.5 · 点按对焦 + 原生相机风格对焦框）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：P0（对焦锁定，ADR-018）与变焦双输入（ADR-019）已完成并部署真机。
"手动干预解锁"入口已存在：CameraStreamer.requestRefocus()（当前只接锁定态，
本批次要扩展为"任意状态 → 到点 AF → 收敛重锁定"的点按路径）。

## 动手前必读（按顺序，全部读完再写代码）
1. focus-dial-plan.md —— P1.5 条目与验收约束
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/decisions.md —— ADR-003（手动曝光不动）、ADR-018（P0 锁定状态机）、
   ADR-019（变焦双输入：预览层已挂 MagnificationGesture，点按手势要与之共存）
4. 现状锚点：
   - ios/AimPhone/ContentView.swift —— CameraPreview 是 layerClass 重写的
     UIViewRepresentable；预览层已有二指变焦手势；横屏 MousePadOverlay 只占底部
     左右键 22%×19% / 滚轮 14%×34%；glass* 兼容封装在文件尾部扩展；
     tickZoom/snapZoom 是刻度触觉+吸附的现成范式
   - ios/AimPhone/CameraStreamer.swift —— P0 对焦状态机（focusFeed/unlockFocus/
     requestRefocus，"对焦锁定状态机" MARK 分区）、applyDeviceSettings 唯一配置点

## 执行内容
严格按方案 P1.5 执行：
1. 坐标转换：CameraPreview 的 Coordinator 持有 PreviewView 弱引用，对外暴露
   "屏幕点 → captureDevicePoint" 转换（AVCaptureVideoPreviewLayer
   .captureDevicePointConverted(fromLayerPoint:)），ContentView 不直接碰 layer
2. CameraStreamer 新增 tapToFocus(at devicePoint:)：isFocusPointOfInterestSupported
   前置检查 → focusPointOfInterest = point + focusMode = .autoFocus（单次 AF 到点）；
   与 P0 联动 = 手动干预解锁 → 到点 AF → 收敛后按 P0 稳定判定（连续 1s 检出 ≥6/8）
   重新锁定；autoFocusRangeRestriction = .near 保留；曝光不动（ADR-003，
   不挂 exposurePointOfInterest）
3. 手势接线：预览层加 SpatialTapGesture，与既有 MagnificationGesture 共存
   （单击 vs 双指天然不冲突）；扫码中（ScanOverlay 显示时）禁用；
   横屏与 MousePadOverlay 共存（它只占底部局部区域，冲突时鼠标控件优先）
4. 对焦框 UI（与原生相机一致 + Liquid Glass）：系统黄四角括号方框，点击处弹出 →
   缩放收敛动画 → AF 收敛或 ~1.5s 后淡出；容器走现有 glassRounded 封装，
   禁止引入第二种玻璃实现；落指 UIImpactFeedbackGenerator(.light)
5. 前置降级：设备不支持点按对焦（部分前摄）时手势不挂、UI 无入口

## 硬约束
- 不改协议；注释全中文，新文件带 L0 文件头；改行为同步改注释
- DockKit 与对焦行为只能真机验证，模拟器全路径静默降级
- 完成后必须跑：
    cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
- 一个 git commit，message 写明验收结果

## 验收门槛（真机冒烟）
- 竖屏点击画面任意位置出对焦框并重新对焦；对焦框动画与原生相机观感一致
- 横屏点底部鼠标区不触发对焦、点其余区域触发
- 二指变焦与点按对焦互不干扰（先放大再点按、点按后再放大都正常）
- P0 锁定逻辑不被点按打乱：点按 → 解锁 → 收敛 → 自动重锁定（看 FOCUS 日志）
- 数码变焦 >1× 时点按位置的坐标转换仍正确（captureDevicePointConverted 与
  videoZoomFactor 的交互要真机验证）

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. 验收小结（竖屏/横屏/扫码中/变焦态四种状态行为 + 真机主观描述，注明机型）
3. 新增 ADR（点按对焦一条，编号按 decisions.md 顺延，预计 ADR-020）；docs/modules.md 同步
4. 未决风险与 P1（轮盘对焦微调，输入通道待决策）/P2 的衔接评估
```

---

## 暂缓批次备忘（不要直接发，需用户先决策）

- **P1 轮盘对焦微调**：轮盘已被变焦占用（ADR-019）。要做 `nudgeFocus` 需先定输入通道：
  轮盘目标循环切换态 / 其他修饰组合 / 或改为屏幕手势。决策后参照旧第三批提示词骨架
  （git 历史可查）重写。
- **P2 refocus 协议**：等 P0 正式命中率/σ 对照数据出来再决定是否启动
  （focus-dial-plan.md P2 条目）。
