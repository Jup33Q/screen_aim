# 边角定位缺失修复 + 白点滤波增强 · kimi cli 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 分次发更稳：先发「第一批：WP1 + WP3」（纯软件，零 UI 风险），验收通过后发「第二批：WP2 卫星标记」。
> 方案全文（数据依据、机制分析、验收门槛）见 docs/edge-localization-and-filter-plan.md。
> 注意：新增 ADR 动手前以 docs/decisions.md 实际最大编号为准顺延（当前最新 ADR-012，预计从 ADR-013 起）。

---

## 第一批提示词（WP1 仿射兜底 + 滑行 / WP3 滤波增强）

```text
# 任务：ScreenAim 边角定位修复 第一批（WP1 + WP3）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
批次：第一批 = WP1（3 点仿射兜底 + 单应滑行）+ WP3（白点滤波增强 + 口语化调参面板）。
第二批（WP2 卫星标记）等我确认后再做。

## 动手前必读（按顺序，全部读完再写代码）
1. docs/edge-localization-and-filter-plan.md —— 本次任务书：§0 问题机制（数据依据）、
   §1 WP1、§3 WP3、§4 验收门槛、§6 风险登记
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/architecture.md —— 线程模型与坐标系约定（新代码不得违反）
4. docs/protocol.md —— 线上格式；localAim 新增 quality 字段必须只加不删、旧端忽略
5. docs/decisions.md —— 既有 ADR 格式；新决策按实际最大编号顺延追加
6. 现状代码：Sources/ScreenAimCore/ScreenLocalizer.swift（≥4 对 RANSAC 门、registerNoAim）、
   Sources/ScreenAimCore/Homography.swift（ransacSrc/leastSquaresSrc 结构）、
   Sources/ScreenAimCore/OneEuroFilter.swift、
   Sources/ScreenAim/main.swift Calibrator.dotFilterX/Y（Mac 端白点二段滤波，约 L525–536）

## 执行内容（本批次）
严格按方案 §1 与 §3 执行：
- WP1.1 仿射兜底：恰好匹配 3 对时退化为仿射变换（三点闭式解）；
  必须带发散护栏——映射瞄点超出三点凸包 1.5 倍范围时仍返回 nil；
  localAim 上报与 CSV 加可选字段 quality（homography/affine/coast），旧端忽略
- WP1.2 单应滑行：检出 <4 且仿射护栏不满足时，沿用上一有效变换外推最多 5 帧，
  输出标 quality=coast；超 5 帧才返回 nil。与 WP3 滤波层的速度衰减外推共用同一实现，
  禁止两处各写一份
- WP3.1 跳变门限：新样本与预测距离 > k×近期 σ（k 默认 2.5，可关）时本帧保持预测输出
- WP3.2 断帧滑行：无瞄准帧按最近低通速度外推 + 速度指数衰减（半衰期 ≈100ms），
  与 WP1.2 同机制；iPhone ScreenLocalizer 与 Mac dotFilter 双端共用
- WP3.3 双端滤波分层解耦：iPhone 段强消抖（对识别噪声），Mac 段只做 15Hz→60fps
  显示插值平滑 + 跳变门 + 滑行，不再重复消抖；两段参数显式分离命名，注释写清各管什么
- WP3.4 口语化调参面板（硬性交付物）：按方案 §3.3 交付预设三档
  （稳如三脚架/日常跟手/疾速响应）+ 四个单项旋钮的「人话调参指南」，
  每个旋钮带底层参数映射、取值范围、「往哪边调是什么感觉」的一句话说明，
  写进 docs/ 并在根 README 实测表附近挂链接

## 硬约束
- 不改 UI 布局与交互（ContentView.swift、Calibrator 视觉样式不动）
- 不改既有协议字段语义；新增字段只加不删；注释全中文，新文件带 L0 文件头
- 像素数据不进主线程；SerialQueue 约定不变；改行为同步改注释
- 每个 WP 完成后必须跑：
    swift build && swift run ScreenAim --self-test
  iOS 侧改动后必须跑：
    cd ios && xcodegen generate && xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
  （签名失败可接受，编译错误不可接受）
- 每 WP 一个 git commit，message 写明验收结果

## 验收门槛（不过门槛不得进入下一 WP）
- WP1：self-test 新增场景全过——只放 3 个相邻标记（角 + 两边中点），瞄点在簇内有输出
  且误差 < 5pt；瞄点强外推（超出 1.5× 凸包护栏）无输出；
  用 scenes/ 既有基准回放，三点簇帧转化率 ≈100%，护栏外零假阳性
- WP3：静止 σ 不劣化于现状（0.05–0.08pt 级）；注入单帧 15pt 人工跳变白点不甩；
  断流 3 帧内白点平滑滑行不消失；「疾速响应」档横扫滞后明显小于「稳如三脚架」档
  （全部实测数值写进验收小结，注明机型/分辨率/标记尺寸条件）
- WP3.4：口语化调参表随代码同提交，预设/旋钮与底层参数映射逐项可对

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. 每 WP 的验收小结（实测值 vs 门槛，注明条件）
3. 新增 ADR（仿射兜底 + 滑行一条；滤波三层增强一条；编号按 decisions.md 顺延）；
   docs/protocol.md（quality 字段）、docs/modules.md、docs/architecture.md 同步
4. 口语化调参指南文档
5. 未决风险与第二批（WP2）的准备情况
```

---

## 第二批提示词（WP2 角标卫星标记，第一批验收通过后再发）

```text
# 任务：ScreenAim 边角定位修复 第二批（WP2 卫星标记）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：WP1/WP3 已完成并验收（仿射兜底、滑行、滤波增强、quality 字段均已落地）。
动手前重读 docs/edge-localization-and-filter-plan.md §2、docs/comment-style.md、
docs/protocol.md §6；现状锚点：Sources/ScreenAim/main.swift Calibrator.rebuildMarkers
（约 L676–733，8 标记布局 + 白卡 + 刘海约束）、calibPayload（约 L758，centers.count == 8 的
guard 需放宽）、Sources/OpenCVBridge 自检场景生成、tools/make_test_scenes.py 与
tools/make_bench_scenes.py。

## 执行内容
严格按方案 §2 执行：
- 每个角标记（id0–3）内侧沿两条边各加 1 个卫星标记（id 8–15，DICT_4X4_50 内），
  共 8 个；默认 18pt（独立 --satellite-size 可调），自带白卡（沿用 pad 静区规则）；
  中心沿边偏移 ≈ 主白卡半宽 + 卫星白卡半宽 + 8pt 间隙；
  上两角沿顶边的卫星沿用 id4 的 safeAreaInsets.top 刘海约束
- CLI 新增 --satellites（默认关）；calib payload 的 markers 开放字典自动带新条目，
  协议格式不变；iPhone 端零改动（ScreenLocalizer 按 id 匹配）
- OpenCVBridge 自检场景与 tools 两个基准脚本同步支持卫星标记；
  make_bench_scenes.py 新增「近距瞄角」基准组（画面只覆盖约 1/4 屏幕）

## 硬约束与验收（同第一批规则，另加）
- 每步后：swift build && swift run ScreenAim --self-test；
  iOS 无改动则不需要 xcodebuild（如有改动仍须编译过）
- 真机 A/B（必须做，不能跳过）：同一贴角瞄准轨迹，关/开卫星各录 3 分钟 localaim CSV，
  用 tools/plot_localaim.py 分析——屏幕四角格（3×3 分格）有瞄准帧率提升目标 +30pp 以上，
  中心区域静止 σ 不劣化。达标才把 --satellites 默认值改为开，否则保持默认关
- 卫星标记的视觉遮挡影响写进验收小结（截图对比）

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. A/B 对比数据结论（边角可用率、中心 σ、截图）
3. 新增 ADR（卫星标记结论：去/留的判定依据与实测数字，编号按 decisions.md 顺延）；
   docs/modules.md、docs/architecture.md、根 README 实测表同步
4. markers=0 类缺失（方案 §0 声明不在本方案射程）的后续立项建议
```
