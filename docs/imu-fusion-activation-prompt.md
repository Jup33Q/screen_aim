# IMU 辅助白点定位 · kimi cli 激活提示词

> 用法：进入项目目录后，把下方「提示词正文」整段发给 kimi cli。
> 严格分批：先发「第一批：WP-I1」（纯测量尖刺，零行为变化），拿到四问数据并过决策门后
> 再发「第二批：WP-I2」；「第三批：WP-I3」是评估项，等我确认 WP-I2 的 A/B 结论后再说。
> 方案全文（边界条件、机制、验收门槛、风险登记）见 docs/imu-fusion-plan.md。
> 前置：WP-L1（60Hz 匀速外推显示，ADR-015）、滤波双端分层（ADR-014）已落地——
> AimCoastFilter.displayExtrapolation、placeAimDot 共用换算、60Hz 显示定时器均已存在。
> 注意：新增 ADR 动手前以 docs/decisions.md 实际最大编号为准顺延（当前最新 ADR-015，
> 预计从 ADR-016 起）。

---

## 第一批提示词（WP-I1 · CoreMotion 采样基线尖刺）

```text
# 任务：ScreenAim IMU 辅助定位 第一批（WP-I1 · CoreMotion 采样基线尖刺）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
批次：第一批 = WP-I1（iPhone 端 deviceMotion 100Hz 采样，只采不融，零行为变化）。
第二批（WP-I2 Mac 显示段 IMU 外推）等我确认四问数据后再做；WP-I3 暂缓。

## 动手前必读（按顺序，全部读完再写代码）
1. docs/imu-fusion-plan.md —— 本次任务书：§0 边界条件、§1 WP-I1、§5 风险登记
2. docs/comment-style.md —— 注释五级体系规范，违反视为不合格
3. docs/protocol.md §10/§11 —— 采集回传管道（type 11 帧复合 payload），motion 数据走这里
4. docs/architecture.md —— 线程模型与坐标系约定；docs/development.md —— iOS 构建命令
5. 现状代码：ios/AimPhone/CameraStreamer.swift（captureOutput 串行队列、帧 PTS）、
   ios/AimPhone/CaptureRecorder.swift（meta.jsonl 每帧一行的产出点）、
   tools/plot_localaim.py（分析工具风格参考）

## 执行内容（本批次）
严格按方案 §1 执行：
- 新增 ios/AimPhone/MotionSampler.swift：CMMotionManager deviceMotion 100Hz，
  记录 rotationRate（已扣零偏）/ attitude 四元数 / timestamp；
  跟随采集会话（captureStart/Stop）启停，不采集时不运行；对现有识别/推流零影响
- CaptureRecorder 的 meta.jsonl 每帧 json 追加 motion 字段（该帧 PTS 前后最近的
  若干运动样本，只加不删；字段缺席时旧分析工具照常工作）
- 新增 tools/plot_imu_baseline.py：回答方案 §1 的四个决策问题——
  ① motion 时间戳与帧 PTS 对齐残差分布；② 白点位移主相关转轴（分竖/横屏）；
  ③ px/rad 比例系数同距离散布与随距离变化；④ 静止 30s 姿态积分漂移率
- 真机录制 ≥4 组会话（竖屏/横屏 × 手持/云台 docked），每组含静止段 + 匀速横扫段
  + 变向段，落盘 scenes/capture_* 三件套留档

## 硬约束
- 不改任何识别/滤波/协议行为：motion 只是 meta 里的一个新字段，不上行新消息类型；
  注释全中文，新文件带 L0 文件头；改行为同步改注释
- 完成后必须跑：
    swift build && swift run ScreenAim --self-test && swift run ScreenAim --filter-self-test
    cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
- 一个 git commit，message 写明四问结论摘要

## 验收门槛
- 四问数据表（标注机型/系统/采集距离）；决策门：比例系数同距离散布 < ±20% 且
  漂移支持 ≥120ms 外推 → 建议进 WP-I2；不达标给出降级结论（方案关闭理由）
- Mac 端 self-test 无回归；AimPhone 编译通过；采集三件套齐整

## 交付物
1. 改动文件清单（逐个说明改了什么）
2. 四问数据验收小结（含真机条件标注）
3. 进/不进 WP-I2 的明确建议与依据
4. 本批次不动 ADR（纯测量尖刺）；docs/modules.md 登记 MotionSampler
```

---

## 第二批提示词（WP-I2 · Mac 显示段 IMU 驱动外推，WP-I1 决策门通过后再发）

```text
# 任务：ScreenAim IMU 辅助定位 第二批（WP-I2 · Mac 显示段 IMU 驱动外推）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：WP-I1 已完成，四问数据过决策门（数据见 WP-I1 验收小结）。
动手前重读 docs/imu-fusion-plan.md §0/§2、docs/whitedot-latency-plan.md §1、
docs/comment-style.md、docs/protocol.md §7；现状锚点：
Sources/ScreenAimCore/AimCoastFilter.swift（displayExtrapolation）、
Sources/ScreenAim/main.swift Calibrator（60Hz 显示定时器、placeAimDot 共用换算）、
ios/AimPhone/CameraStreamer.swift（localizeFrame 的 localAim 上报点）、
ios/AimPhone/MotionSampler.swift（WP-I1 产物）。

## 执行内容
严格按方案 §2 执行：
1. iPhone 端在线标定 + 快照上行：相邻视觉检出对（仅 homography/affine 参与）
   用 IMU 积分角增量 ÷ 视觉位移更新比例系数 EWMA（符号一并在线标定，禁止手写
   轴向映射表）；置信样本数 <20 不上报；localAim 帧追加可选字段
   "gyro":{"t":帧PTS,"rate":[wx,wy],"age_ms":N}（单位 pt/s，已投影已乘系数；
   只加不删，旧 Mac 忽略）
2. Mac 显示段：60Hz 定时器外推分支——gyro 新鲜（age ≤250ms）用
   lastOut + gyroRate×Δt；否则回退 coastVel 匀速外推（WP-L1 行为原样保留）；
   封顶/钳制/y 翻转全部走既有 placeAimDot，禁止第二份换算
3. 静止死区：|gyroRate| < 阈值（默认 2pt/s，--dot-* 风格旋钮）视为零
4. CLI 开关 --imu-display，默认关；localaim CSV 加 imu_rate 列（只加不删）
5. --filter-self-test 加子测试：合成已知角速度曲线 + 15Hz 视觉锚点，
   变向段 IMU 外推误差 < 匀速外推 50%；静止段漂移 < 0.1pt；
   gyro 缺失/过旧时与 WP-L1 行为逐点一致（回归门）

## 硬约束与验收（同第一批规则，另加）
- 真机 A/B：同轨迹横扫 + 变向各 3 分钟，--imu-display 开/关，
  变向/加减速段轨迹相位差较 WP-L1 基线再降 ≥40%；静止 σ 不劣化；跳变门行为不变。
  不达标不翻默认，记录结论
- 必跑：
    swift build && swift run ScreenAim --self-test --filter-self-test
    cd ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -destination 'generic/platform=iOS' build
- 一个 git commit，message 写明 A/B 结论

## 交付物
1. 改动文件清单
2. A/B 对比结论（变向段相位差、静止 σ、跳变门回归）与默认值去/留判定
3. 新增 ADR（IMU 外推一条，编号按 decisions.md 顺延，预计 ADR-016）；
   docs/protocol.md（gyro 字段）、docs/architecture.md（运动数据流）、
   docs/modules.md 同步
4. WP-I3 评估所需数据的准备情况
```

---

## 第三批提示词（WP-I3 · iPhone 识别段 IMU 传播评估，WP-I2 验收通过后再发）

```text
# 任务：ScreenAim IMU 辅助定位 第三批（WP-I3 · 识别段 IMU 传播，评估先行）

工作目录：/Users/jup33q/Documents/kimi/screen_aim
前置：WP-I2 已完成并验收。动手前重读 docs/imu-fusion-plan.md §3、
docs/whitedot-latency-plan.md §2（WP-L2 提频评估，本批要与它做收益对比）、
docs/comment-style.md；现状锚点：Sources/ScreenAimCore/ScreenLocalizer.swift、
ios/AimPhone/CameraStreamer.swift（localizeFrame 节流）、tools/plot_localaim.py。

## 执行内容
严格按方案 §3「评估门后再实施」执行：
1. 先出评估报告（不改行为）：用 WP-I1/WP-I2 留档数据离线模拟"若识别帧之间有
   IMU 传播输出（30Hz，quality=imu）"，横扫滞后与轨迹误差对比现状及 WP-L2
   提频预期；只有收益显著大于 WP-L2 且静止 σ 可保住才进入第 2 步，否则记录
   结论关闭 WP-I3（WP-L2 去留一并给建议）
2. 实施（评估门通过后）：ScreenLocalizer 下游互补传播——最近视觉变换 + IMU
   角增量 × 在线系数 → 传播瞄准点，quality="imu"（只加不删，旧端忽略）；
   限频 30Hz、时距封顶同 WP-I2；imu 帧按"测量"对待——重置滑行计数、参与跳变门
   残差统计；视觉帧到达即重置权威值
3. A/B：横扫滞后较 WP-I2 基线再降 ≥30%；静止 σ 不劣化；imu 帧轨迹与视觉帧
   无系统性偏移。全达标才保留，否则回退并记录

## 硬约束与验收（同前两批规则）
- 提频/传播是可逆开关（CLI/常量），不是写死
- 必跑 Mac self-test + filter-self-test + iOS xcodebuild（命令同前两批）
- 一个 git commit，message 写明评估/AB 结论

## 交付物
1. 评估报告（离线模拟数据，WP-I3 与 WP-L2 的收益对比）
2. 若实施：A/B 结论与去/留判定；新增 ADR（编号顺延）；
   docs/protocol.md（quality 新等级）、docs/aim-filter-tuning.md（时间轴假设）同步
```
