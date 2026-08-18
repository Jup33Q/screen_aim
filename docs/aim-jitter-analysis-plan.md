# 白点连续性与抖动分析方案（JA0–JA3）

> 状态：**JA0 已完成**（skills/aim-jitter-analysis 落地：SKILL.md + references/metrics.md +
> scripts/jitter_report.py，经 2026-08-17 真机会话 56k 帧实测验证）。JA1–JA3 待实施。
> 激活提示词见文末 §5。
> 前置阅读：[protocol.md](protocol.md) §7（localAim 上报语义）、
> [aim-filter-tuning.md](aim-filter-tuning.md)（滤波两段结构与预设/旋钮）、
> [tlv-blocking-optimization-plan.md](tlv-blocking-optimization-plan.md)（链路排队根因）、
> [skills/aim-jitter-analysis](../skills/aim-jitter-analysis/SKILL.md)（指标怎么读）。

## 0. 目标与问题清单

白点手感 = 连续性（不卡不消失）× 静止稳定性（不抖）× 运动跟手性（不拖）。
现有观测手段的缺口：

| # | 缺口 | 影响 | 位置 |
|---|---|---|---|
| ① | localaim CSV 的 timestamp 是 Mac 到达时刻，无手机采集 PTS | 链路抖动与端侧识别耗时无法分离；跳变事件的"真实发生时刻"不可考 | iOS `CameraStreamer.localizeFrame` → Mac `logLocalAim` |
| ② | 无发送时间戳，过时消息不可识别 | 网络攒批恢复后旧瞄准点重放，白点"追历史"（500ms TTL 方案缺数据基础） | protocol.md §7 localAim 消息格式 |
| ③ | 旧会话无 quality 列，抖动无法按 homography/affine/coast 分层 | coast 段抖动（外推不稳）与真实识别抖动混在一起 | Mac `logLocalAim` 表头（已支持，需新客户端跑数据） |
| ④ | 滞后（lag）无测量通道 | "甩动跟不跟手"只能靠 `--filter-self-test` 合成信号，真机无对照 | 无真值通道，JA3 用动作脚本替代 |

已具备、**不要动**的正确基础：`tools/plot_localaim.py`（成功率/轨迹）、
`--filter-self-test`（确定性合成信号）、AimCoastFilter 两段滤波结构（ADR-014）。

## 1. JA0：分析工具落地（已完成）

交付：`skills/aim-jitter-analysis/`（SKILL.md + references/metrics.md +
scripts/jitter_report.py）。
四面板报告：dt 分布 / 帧间位移时间线（静止段+跳变标记）/ 轨迹 / 最长静止段功率谱；
控制台指标表含分 quality 分层（旧文件自动降级）。

**实测基线**（2026-08-17T06-19-57Z 会话，56k 帧，旧客户端无 quality）：

- 有效率 34.4%，dt p50=31ms / p95=44ms / p99=89ms（该会话约 30Hz 上报）
- 断流(>500ms) 115 次累计 1125s（含挂起）；网络攒批 34%
- 静止段帧间位移：RMS=2.41pt，p95=4.33pt（可感知轻微颤动区间）
- 跳变 1064 次，最大 59873pt 且 markers=4–5 —— **4 标记单应退化翻转是真问题**，
  不是分析噪声；对应屏幕角落标记的遮挡/反光排查（ids 列定位缺哪个）

## 2. JA1：消息时间戳与分层数据补强（双端小改动）

**目标**：让"过时消息识别"与"链路/端侧耗时分离"有数据基础。

1. iOS `CameraStreamer.localizeFrame` 的 localAim 消息加两个字段
   （protocol.md §7"只加不删"，旧 Mac 忽略）：
   - `"ts"`：发送墙钟（`Date().timeIntervalSince1970`，秒）
   - `"pts"`：相机帧 PTS（`localizeFrame` 已有的 `timestamp` 参数，秒）
2. Mac `logLocalAim` 表头追加 `ts,pts` 两列（旧 CSV 无此列 = 空，向后兼容）。
3. Mac `handlePhoneControl` localAim 分支：用 `ts` 做超龄丢弃（估算年龄 > 500ms
   丢弃并计数，自校准偏移 = 滑动窗口 `min(到达-ts)`，免疫恒定钟差）；
   丢弃计数进 debug 标签，不进 CSV（避免污染分析数据）。

**验收**：
- 新会话 CSV 带 ts/pts/quality 列，`jitter_report.py` 跑通且分 quality 表有输出
- pts-timestamp 差值（端侧管线延迟）p95 有数；ts 超龄丢弃计数在强网基线 ≈ 0
- 旧客户端连新 Mac：行为不变（无 ts 不丢弃）

## 3. JA2：A/B 预设对比实验（纯数据工作，无代码改动）

固定动作脚本（每档重复 3 次取中位）：

1. 静止 10s（手持对准屏幕中心）
2. 慢速画圆 10s → 快速左右横扫 ×3
3. 遮挡一个角标记 5s → 恢复；遮挡两个角 5s → 恢复

每档 `--filter-preset stable|daily|fast` 各跑一轮，逐 CSV 跑 `jitter_report.py`，
产出对比表：静止 p95 / 跳变次数 / 遮挡恢复后 1s 内跳变数 / dt p95 / 攒批率。

**验收门**（任一不达标则回 aim-filter-tuning.md 调旋钮并重测）：
- stable 档静止 p95 ≤ 2pt；fast 档横扫段跳变 ≤ daily 档 1.2 倍
- 遮挡恢复后追平跳变 ≤ 1 帧（gateK 设计语义："最多被压 1 帧"）

## 4. JA3：指标日常化（可选，接 Canvas）

把 JA2 的对比表核心列（静止 p95、跳变次数、dt p95、攒批率）做成
「AimPhone 识别质量 · localAim」Widget 的聚合维度，Automation 每次会话结束
（或手动触发）跑 `jitter_report.py` 并抽取指标。**JA2 数据验证了指标稳定性后再做。**

## 5. 激活提示词

### JA1 激活提示词（双端改动）

```
激活 docs/aim-jitter-analysis-plan.md 的 JA1。先完整读该 plan、docs/protocol.md §7、
docs/comment-style.md，再读 ios/AimPhone/CameraStreamer.swift 的 localizeFrame、
Sources/ScreenAim/main.swift 的 logLocalAim 与 handlePhoneControl 的 localAim 分支、
skills/aim-jitter-analysis/references/metrics.md。

按 plan §2 实施，一次完成，改完停下来汇报：
1. iOS localAim 消息加 "ts"（发送墙钟秒）与 "pts"（相机帧 PTS 秒）两个字段，
   协议只加不删，旧 Mac 兼容；字段语义注释写清单位与时钟域。
2. Mac logLocalAim 表头追加 ts,pts 两列（quality 之后），旧客户端上报缺字段时留空；
   CSV 表头变化要在注释里标注版本。
3. Mac localAim 分支加 500ms 超龄丢弃：估算年龄 = (到达-ts) - 滑动窗口min(到达-ts)，
   超龄丢弃并计数，计数显示在 debug 标签；无 ts 的旧客户端消息不丢弃。
   鼠标/采集/断开兜底消息一律不走 TTL。

硬约束：不改 TLV 线上格式与既有字段语义；注释遵循 comment-style.md；
断流滑行与跳变门（AimCoastFilter）逻辑不动；改完跑
swift build && swift run ScreenAim --self-test，
再用真机会话产一份新 CSV，跑
python skills/aim-jitter-analysis/scripts/jitter_report.py 验证分 quality 输出。
```

### JA2 激活提示词（对比实验）

```
激活 docs/aim-jitter-analysis-plan.md 的 JA2。先读该 plan §3、
docs/aim-filter-tuning.md、skills/aim-jitter-analysis/SKILL.md 与 references/metrics.md。

我负责按动作脚本（静止10s → 慢速画圆 → 快速横扫×3 → 遮挡单角/双角各5s+恢复）
分别跑 stable / daily / fast 三档预设，每档产一个 localaim CSV 后叫你。
你负责：对每个 CSV 跑 python skills/aim-jitter-analysis/scripts/jitter_report.py，
汇总对比表（静止 p95 / 跳变次数 / 遮挡恢复后1s内跳变数 / dt p95 / 攒批率 /
分 quality 位移 p95），对照 plan §3 验收门给结论；
不达标项给出 aim-filter-tuning.md 旋钮级别的调整建议（哪档、哪个旋钮、往哪边、
预期影响什么指标）。不要改任何代码。
```
