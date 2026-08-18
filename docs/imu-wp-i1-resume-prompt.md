# WP-I1 续跑激活提示词（录制中断于手机散热，2026-08-17 晚）

> 用法：新会话直接粘贴本文件「激活提示词」一节。背景与四问定义见 docs/imu-fusion-plan.md §1。

## 激活提示词

```
继续 ScreenAim WP-I1（IMU 采样基线尖刺）的录制与分析。工作目录
/Users/jup33q/Documents/kimi/screen_aim，先读 docs/imu-fusion-plan.md §1 和
docs/imu-wp-i1-resume-prompt.md（本文件）的"现场状态"。

代码部分已全部完成并验证（MotionSampler 100Hz 采样、CaptureRecorder meta.jsonl
motion 字段、tools/plot_imu_baseline.py 四问分析、Mac 双自检通过、iOS 编译通过）。
剩余工作：
1. 补录缺失的采集会话（清单见"录制进度"），流程见"录制操作要点"；
2. 录齐后跑 python3 tools/plot_imu_baseline.py scenes/capture_imu_*，出四问数据表
   （标注机型 iPhone 15 Pro Max / iOS 26 / 采集距离 d65≈屏幕占画面65%、d40≈40%）；
3. 按决策门（比例系数同距离散布 <±20% 且漂移支持 ≥120ms 外推）给进/不进 WP-I2 的结论；
4. 一个 git commit（message 写四问结论摘要）。注意工作树里有其他会话的未提交 WIP
   （ContentView/TLVTransport/FrameServerV2/main.swift/MarkerDetector 的既有改动），
   提交时只部分暂存 WP-I1 相关 hunk。
```

## 现场状态

### 已完成的代码（未提交）
- `ios/AimPhone/MotionSampler.swift`（新）：deviceMotion 100Hz，采集会话启停跟随；
- `ios/AimPhone/CaptureRecorder.swift`：meta.jsonl 每帧追加 `motion` 字段
  （PTS ±0.15s 样本 `[dt,wx,wy,wz,qx,qy,qz,qw]`，延迟一帧写出）；
- `tools/plot_imu_baseline.py`（新）：四问分析 + 决策门汇总；
- `docs/modules.md` / `docs/protocol.md` §10：已同步。
- 顺手修复（同批未提交）：MarkerDetector decode 护栏（prefilter 幸存者按四边最弱对比度
  降序、maxCandidates 回到 32——256 在无标记夜景 553ms/帧）；ContentView 右上角标记数
  徽标（N.circle 可变符号，variableValue=N/8）；ContentView `isIdleTimerDisabled=true`
  （录制中途自动锁屏曾把 10s 会话截成 6 帧）。

### 关键教训（务必遵守）
- **手机必须部署 Release 构建**：Debug -Onone 下检测 550–1000ms/帧（白天的 8ms 全是
  Release）。部署命令：
  ```bash
  cd ios && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project AimPhone.xcodeproj -scheme AimPhone -configuration Release \
    -destination 'id=C8455114-3D2A-5809-8BDD-54AA740F0542' build
  APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/AimPhone-*/Build/Products/Release-iphoneos/AimPhone.app | head -1)
  xcrun devicectl device install app --device C8455114-3D2A-5809-8BDD-54AA740F0542 "$APP"
  xcrun devicectl device process launch --terminate-existing \
    --device C8455114-3D2A-5809-8BDD-54AA740F0542 com.screenaim.AimPhone
  ```
- Mac 服务端由用户自行运行（`.build/debug/ScreenAim --calibrate --serve 9100`，
  录制按钮可用 kimi-cu 按 pid 点 AXButton index 4，或让用户点）。
- **姿态标签以 IMU 重力主轴为准，不信口头约定**：g_dev 主轴 y=竖屏、x=横屏
  （四元数 v_ref=R·v_dev，g_dev=Rᵀ·(0,0,-1)）。用户曾全程横屏却按竖屏报，已纠正一批目录名。
- Mac 侧目录时间戳 = 回传到达时刻；`session.json` 出现才算回传完成，此前别读 meta.jsonl；
  `ls -dt scenes/capture_m48_i24_*` 会混进旧会话，比较基线排除。
- 录制坏档（帧数过少/无瞄准点）移到 `scenes/_discard/`。

### 录制进度（✅=已落盘并重力验证）
| 组合 | 静止 | 横扫 | 变向 | 备注 |
|---|---|---|---|---|
| 横屏手持 d65 | ✅ 12-24-14 | ✅ 12-34-31 | ✅ 12-43-38 | 另有 mix 两段 12-00-33 / 12-03-12 |
| 竖屏手持 d65 | 缺 | 缺 | ✅ 12-35-50 | |
| 竖屏云台 d65 | 缺 | 缺 | 缺 | |
| 横屏云台 d65 | 缺 | 缺 | 缺 | 另有 mix 一段 12-14-13 |
| 竖屏手持 d40 | 缺 | 缺 | 缺 | 远距（屏幕占画面 ~40%） |
| 横屏手持 d40 | 缺 | 缺 | 缺 | |

### 录制操作要点（每段）
1. 请用户摆好机位姿态并确认 → 点 Mac 标定层录制按钮（10s@5fps 固定）；
2. 用户执行该段动作（静止=全程不动；横扫=匀速、屏幕不出画面；变向=快速换向 3-5 次）；
3. 等 `session.json` 出现后校验：帧数 ≥25、有瞄准点帧占比（静止/横扫段应 >80%）、
   rotRate 范围符合段语义（静止 <0.1、横扫/变向 >0.2）、重力主轴与标签一致；
4. 改名 `scenes/capture_imu_<pt|ls>_<hand|dock>_<d65|d40>_<static|sweep|dir>_<原时间戳>`。
