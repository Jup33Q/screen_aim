# 定位算法优化路径调研与实施方案

> 日期：2026-08-16 · 优先级约束：**识别质量 > 传输速度 > 其他** · 推送间隔目标：50–100ms（10–20Hz）
>
> 调研范围：本项目现状诊断 → 定位码（fiducial）方案对比 → Swift Vision 生态替代/优化 →
> SIP/OSC/MQTT/私有协议/蓝牙传输评估 → 分阶段实施步骤。

---

## 0. 现状诊断（代码事实）

| 环节 | 现状 | 瓶颈 |
|---|---|---|
| Mac 检测 | OpenCV `ArucoDetector` DICT_4X4_50，`CORNER_REFINE_SUBPIX` 已开，1280 宽降采样 | 依赖 Homebrew OpenCV；要求 4 角**恰好集齐**，缺一即无输出 |
| iPhone 检测 | 纯 Swift ArUco（`ScreenAimCore/MarkerDetector.swift`），无亚像素精化，角点误差 ≤ ~0.7px@1280w | 精度上限低于 Mac 端；全帧全量检测，无跟踪/ROI 复用 |
| 视频链路 | 720p JPEG q0.6 @ 15fps（66ms）TCP 推流，端到端约 100ms | JPEG 编解码 + TCP 队头阻塞贡献大部分延迟 |
| 结果回传 | `localAim` 控制帧与视频**共用同一条 TCP** | 大包视频帧与小包控制帧互相排队，推送间隔被视频帧周期绑架 |
| 输出滤波 | 无（README 提到产品化加 One Euro Filter） | 瞄准点抖动直接透传 |

**核心结论**：当前架构是「识别在 Mac、视频走 TCP、结果与控制共用一管」。
50–100ms 推送间隔的最大障碍不是算力，而是 (a) 视频帧周期 66ms 与 (b) 单 TCP 连接内的队头阻塞。

---

## 1. 定位码方案对比（识别质量优先）

### 1.1 学术基准：ArUco / AprilTag / STag / TopoTag

FMAC 公平对比研究（arXiv:2601.07723，2026-01，光线追踪合成图 + 统一 50mm 标记）：

| 标记 | 检出率 | 平移精度 | 角度精度 | 备注 |
|---|---|---|---|---|
| ArUco (OpenCV 4.13) | **100%** | σ≈5.4mm(X)/3.8mm(Y)，Z 系统性高估 | σ 较大，yaw 有 90° 周期误差 | 软件生态最好 |
| AprilTag 3.4.5 | 99.74% | **显著小于 ArUco** | **最优之一** | 存在 ~0.5px 系统性偏移（已知 bug） |
| STag | 84.27%（小标记/贴边掉检） | 与 AprilTag 同级 | 差 | 不适合贴屏角场景 |
| TopoTag | 仅 500–1000mm 近距 | **最优（~0.1mm）** | — | 检测范围窄，不适合 |

对本项目（2D 屏幕单应映射，非 6DoF 位姿）：ArUco 与 AprilTag 精度差异在亚像素角点精化面前是次要的；
**真正影响映射质量的是角点亚像素精度与"4 角集齐率"**。

### 1.2 本项目最优策略：冗余标记 + 最小二乘单应（强烈推荐，收益最大）

当前 `ScreenLocalizer` 要求 id 0–3 恰好全在。改进：

1. **屏幕四角 + 四边中点共 8 个标记**（或 6 个），任取检出 ≥4 个即求解；
2. `getPerspectiveTransform`（4 点精确解）→ `cv::findHomography(..., RANSAC)`（多点最小二乘 + 离群剔除）；
3. 效果：任一角被手指/窗口遮挡或单帧掉检时**仍有输出**——识别"质量"从帧级命中率变成系统级可用率，这是比换字典大得多的提升；
4. iPhone 纯 Swift 端：`Homography.swift` 需扩展为 ≥4 点最小二乘（DLT + SVD 或牛顿迭代），工作量约半天。

### 1.3 亚像素角点精化（iPhone 端补齐）

- Mac 端 OpenCV 已开 `CORNER_REFINE_SUBPIX`；iPhone 纯 Swift 检测器角点取自连通域极值像素（误差 ≤0.7px）。
- 方案：对候选四边在灰度图上做**梯度加权直线拟合**（沿边法向采 8–16 点，加权质心求亚像素边缘位置），两线求交得亚像素角点；或直接在解码出的 6×6 网格上利用边框环内侧 4 个内角的 Otsu 过渡点做精化。
- 预期：中心误差 0.7px → <0.2px，瞄准抖动 σ 进一步压到 0.05pt 以下。

### 1.4 其他候选评估

- **AprilTag (DICT_APRILTAG_36h11)**：OpenCV aruco 模块直接支持，Mac 端改一行字典即可 A/B；iPhone 纯 Swift 端需重写字典与解码（36 bit 码 + 汉明距离校验），工作量中等。精度收益对本场景有限，**列为备选**。
- **ChArUco 棋盘板**：亚像素最好，但屏幕四角放不下棋盘，不适用。
- **WhyCode / 单频标记**：抗运动模糊极强、600+fps，但无成熟 Swift 实现，不优先考虑。
- **无标记方案（屏幕边框检测）**：见 §2.3。

---

## 2. Swift Vision 生态：替代/优化方案（用户指定重点）

### 2.1 VNDetectBarcodesRequest —— 用标准二维条码替代 ArUco

**事实基础**（Apple 官方文档 + 第三方基准）：

- `VNDetectBarcodesRequest`：iOS 11+/macOS 10.13+，**一次请求可检出同帧多个条码**，返回 `VNBarcodeObservation`（含 `boundingBox`、四角点 `topLeft/topRight/bottomLeft/bottomRight`、`payloadStringValue`）。[Apple Developer Docs]
- 支持 symbology：QR、Aztec、**DataMatrix**、PDF417、Micro QR、Code128 等；可设 `symbologies` 白名单收窄以提速。[Apple Docs / WWDC24-10163]
- 性能：神经网络引擎（ANE）加速。第三方静态图基准（Dynamsoft 2026-07，83 张真实照片）：Vision 平均 ~96–98ms/图（全 symbology 白名单、含难样本）；另一基准（it-jim 2025-02）静态图均值 ~70ms。**注意这些是"全格式 + 静态照片"最差情形**；实时相机管线收窄到单一 symbology + ROI 后，业界实测可达每帧数毫秒级（30–60fps 扫码应用即为证据）。需要本机实测，不能照搬静态图数字。
- 精度隐患：同一 Dynamsoft 基准中 Vision 在挑战性图片上**漏检超过一半**（354 个条码中 Dynamsoft 检出数约 3 倍于 Vision）。条码检测器面向近正面拍摄设计，大角度透视畸变下弱于 ArUco。

**三种候选码型对比**（贴屏幕四角，24–48pt 尺寸）：

| 码型 | 定位图形 | 静区要求 | 小尺寸鲁棒性 | 纠错 |
|---|---|---|---|---|
| QR | 3 个回字角 | **4 模块宽静区**（占面积大） | 中（版本 1 也有 21×21 模块） | RS，最高 30% |
| **DataMatrix** | L 形实边 + 对侧点线 | 仅 1 模块 | **最好**（ECC200 最小 10×10 模块） | RS，固定强纠错 |
| Aztec | 中心同心牛眼 | 无（自带） | 好（最小 15×15） | RS 可调 |

**推荐：DataMatrix**，payload 编码 `"aim:0".."aim:3"` 区分四角。静区最小、小尺寸最强、纠错内建（误码率远低于 ArUco 字典匹配）。

**集成方式（两端同一套 Vision 代码，无第三方依赖）**：

```
CVPixelBuffer → VNImageRequestHandler → VNDetectBarcodesRequest(symbologies: [.dataMatrix])
  → [VNBarcodeObservation] → payload 解析 id、四角点取中心 → 既有 Homography → aim
```

- Mac 端收益：**可整体替换 OpenCV**，去掉 Homebrew 依赖与 ObjC++ 桥接层（`Sources/OpenCVBridge` 退役），ScreenCaptureKit 的 `CVPixelBuffer` 直接喂 Vision。
- iPhone 端收益：替代纯 Swift ArUco，检测从 CPU 移到 ANE/GPU，省电省发热；角点为 Vision 亚像素输出，天然优于当前 ±0.7px。
- **风险对冲**：Vision 对大倾角漏检率高（上述基准），因此必须保留 ArUco 通道作为回退，用 `scenes/` 既有 CSV 基准做 A/B：
  - 指标：4 角集齐率、单标记检出率、中心 σ、每帧耗时；
  - 决策门槛：Vision 通道集齐率 ≥ ArUco 通道才切换主通道，否则 Vision 仅作并行校验。

### 2.2 VNTrackObjectRequest —— 检测 + 跟踪混合管线（效率大招）

- WWDC24 明确 Vision 支持跨帧目标跟踪。管线：**全量检测 5–10Hz（Vision 条码或 ArUco）→ 中间帧用 `VNSequenceRequestHandler` + `VNTrackObjectRequest` 跟踪 4 个角标记 → 每帧都出单应**。
- 效果：输出频率与相机帧率（30–60fps）解耦于检测开销；跟踪耗时 <1ms/帧。推送 20Hz（50ms）时 CPU/ANE 占用反而低于现在的 15fps 全量检测。
- 跟丢处理：跟踪置信度下降或 N 帧未全量校验 → 立即全量重检。跟踪结果每 100–200ms 用全量检测校正一次，防漂移。

### 2.3 无标记路线：VNDetectRectanglesRequest 检测屏幕本体

- 屏幕是画面中最亮的矩形。`VNDetectRectanglesRequest`（`maximumObservations=1, minimumConfidence, minimumAspectRatio`）可直接框出屏幕四边 → 四角点直接建单应，**彻底不需要任何标记**。
- 风险：壁纸与屏幕外背景对比不足、屏幕反光、窗口遮挡四角时会失效。
- 定位：**Phase 3 的探索项**，不作为主路径；若实测置信度稳定，可作为"标记全部丢失时"的兜底几何源。

### 2.4 辅助：VNHomographicImageRegistrationRequest / 光流

- 帧间用单应配准估计整机运动，对 aim 输出做运动补偿/预测（与 One Euro Filter 互补），在 50ms 推送间隔内给出更平滑的外推点。
- One Euro Filter（README 已列）：`minCutoff≈1.0Hz, beta≈0.5`，低速消抖、高速低延迟。

### 2.5 结论：Vision 能替代定位码吗？

**能替代"检测器"，不该替代"标记本身"**。最佳组合：

> **DataMatrix 标记（Vision 检测，ANE）为主 + ArUco（纯 Swift/OpenCV）为回退 + VNTrackObjectRequest 填中间帧 + 冗余 8 标记最小二乘单应 + One Euro 输出。**

---

## 3. 传输协议调研（50–100ms 推送）

### 3.1 候选协议逐项结论

| 协议 | 本质 | 50–100ms 小包适用性 | 结论 |
|---|---|---|---|
| **SIP** | VoIP 会话**信令**协议（INVITE/BYE），不传媒体流 | 完全不对口；媒体是 RTP，且引入整套会话状态机 | ✗ 排除 |
| **MQTT** | TCP 发布/订阅，**必须经过 broker**，最小头 2B | 局域网 QoS0 热路径延迟 ~1–10ms 级（MDPI 2021 实测 TTC 最小 7.27ms），但 broker 是额外一跳 + 单点；高频下 broker 排队（1ms IAT 实测丢包 65%） | △ 杀鸡用牛刀，仅在未来多订阅者（看板/录播）时引入 |
| **OSC** | UDP 上的轻量编码（地址 + 类型标签 + 参数），支持 bundle/时间戳 | 点对点 20Hz 小包天然契合；编码/解码 ~µs 级；无内建序号/丢包检测，需自加 | ○ 作为**编码格式**可选项（生态：TouchOSC/Max/PD 可直接监听调试） |
| **裸 UDP（Network.framework `NWConnection`/`NWProtocolUDP`）** | 数据报 | 局域网 RTT 亚毫秒～数毫秒；自加 4B 序号 + 8B 时间戳即可 latest-wins | ◎ **推荐主通道** |
| **QUIC（Network.framework，iOS 15+/macOS 12+）** | TLS1.3 + 多流，无队头阻塞 | 对 20Hz 小包握手/加密开销得不偿失；适合替代 MPC 做可靠通道（见 Stormo 项目） | ○ 仅当需要加密可靠多流时 |
| **MultipeerConnectivity / AWDL（Apple 私有 P2P Wi-Fi）** | 私有协议，无公开 API；经 MC 或 `NWParameters.includePeerToPeer=true` 间接使用 | 吞吐 160–320Mbps（AirDrop 实测级），但 **AWDL 信道跳变会给基础设施 Wi-Fi 带来 50–100ms 周期性延迟尖峰**（Meter 2022 实测，恰好落在我们的推送间隔量级，会造成抖动）；且 iOS 26 起 MPC 无网络场景已坏、框架事实性弃用（Stormo README） | △ 不作默认；`includePeerToPeer` 作为无路由器场地的兜底开关 |
| **BLE（CoreBluetooth）** | GATT notify/write-without-response | 实测 iOS 吞吐 400–600kbps（iOS 16+ 回落自 ~1.2Mbps，Apple Forums 770717）；连接间隔被 iOS 重协商到 15–30ms | ○ **坐标小包可行**（30B×20Hz=600B/s ≪ 上限），视频不可行（720p JPEG ≈ 3.6–7.2Mbps 超上限 10 倍）。价值在**无局域网时的降级通道/配对引导** |

### 3.2 推荐传输架构：双通道分离

```
iPhone                                    Mac
 ┌─ 视频帧（仅 Mac 识别模式才需要）── TCP（现状保留）──────────┐
 │                                                            │
 └─ 识别结果/控制小包 ── UDP 数据报（新增，独立端口）───────────┘
      [seq:u32][t_ms:u64][markers:u8][x:f32][y:f32]  ≈ 25B/包
      10–20Hz 固定节奏，latest-wins，丢包不重传
```

- **为什么分离**：坐标包与 JPEG 大包共管时，坐标包排在 60KB 视频帧后面 = 随机增加 30–50ms 队头延迟。独立 UDP 后推送间隔由发送定时器决定，50–100ms 区间可严格保证（建议固定 50ms / 20Hz，p95 间隔 < 60ms）。
- **OSC 选项**：若希望调试期能用现成 OSC 工具监听，坐标包改用 OSC 编码（`/aim/xy ff`），开销 ~24B，代价可忽略。默认建议自定义二进制，OSC 作为编译开关。
- **不要动的部分**：Bonjour 发现、二维码配对、calib 下发——保持现状，与传输升级正交。

### 3.3 战略分叉点：识别放手机端 = 传输问题消失

按「识别质量 > 传输速度」的优先级推演到底：

- **路线 A（推荐验证）：iPhone 端 Vision 识别 + 只传坐标**。视频不再出手机：无 JPEG 编解码（省 ~15–25ms）、无 TCP 传输（省 ~20–40ms）、端到端延迟 100ms → **<20ms**；ANE 检测不占用应用 CPU；推送间隔与相机帧率解耦，20Hz 轻松。ADR-001 的推翻条件（"延迟敏感场景"）已经触发——本项目正是延迟敏感。
- **路线 B（现状）：Mac 识别**。仅当手机算力/发热验证不通过，或需要 Mac 对"自己屏幕内容"做无手机参与的自检时保留。
- 两端识别框架已有对照基础设施（`localAim` CSV + Dashboard 聚合 Widget），迁移期间双跑对比，数据达标后切主通道。

---

## 4. 分阶段实施方案

### Phase 0 — 测量基线（0.5 天，先行）

1. `localizeFrame` 与 Mac `processJPEG/processBGRA` 打点：采集时间戳、检测耗时、发送时间戳、接收时间戳（UDP 序号对表）。
2. 复用 `scenes/localaim_*.csv` 格式，增加列：`detect_ms, e2e_ms, interval_ms`。
3. 产出：当前 p50/p95 端到端延迟、集齐率、推送间隔分布 —— 作为后续所有 A/B 的对照组。

### Phase 1 — 识别质量（不动架构，1–2 天）

1. **冗余标记 + 最小二乘单应**（§1.2）：Calibrator 改显示 8 标记（4 角 + 4 边中点）；Mac 端 `findHomography(RANSAC)`；iPhone 端 `Homography` 扩展 ≥4 点 DLT。验收：人为遮挡任一角，输出不中断；遮挡两角，误差 < 2pt。
2. **iPhone 亚像素角点精化**（§1.3）。验收：1280w 帧中心 σ < 0.05pt（对齐 Mac 端水平）。
3. **One Euro Filter** 加在 `ScreenLocalizer` 输出侧（两端同一实现放 `ScreenAimCore`）。验收：静止 σ 降 50%+，快速移动无可见滞后。

### Phase 1.4 — 控制信道协议类型化：Codable enum（0.5 天，插入项，建议在 Phase 3 前完成）

1. 现状：protocol.md §6/§7/§8/§10 的全部控制消息与采集记录都是 `[String: Any]` +
   字符串 `type`/`kind`/`button` 手工解包，两端各维护一份魔法字符串（`CameraStreamer.sendControl/handleControl`、
   `main.swift` 的 `server.onControl` switch、`CaptureServer.processRecord`），新增消息无编译期检查、
   键名写错只能运行期发现。
2. 改为 `Sources/ScreenAimCore/AimProtocol.swift` 双端共享的 Codable 定义
   （ScreenAimCore 本就被 XcodeGen 直接编入 AimPhone，零接入成本）；
   自定义编解码保证**线上 JSON 与 protocol.md 现有格式逐字节兼容**（只加不删原则不变）。
3. 覆盖信号清单（闭集字符串 → enum）：控制帧 `type`（双向各一个消息枚举）、
   鼠标 `button`、采集记录 `kind`、localaim CSV `src`、mouse CSV `event`、
   Phase 2 预留 `DetectorKind`。详见 §7.9。
4. 验收：全部消息 round-trip 自检 + protocol.md 内嵌示例 JSON 逐字段比对通过；
   旧端互操作语义不变（未知 type 仍被忽略）。

1. `ScreenAimCore` 新增 `VisionMarkerDetector`：DataMatrix × 8 标记，payload `aim:N`，`symbologies=[.dataMatrix]`；与 `ArucoDetector` 实现同一协议（`detect → [DetectedMarker]`），可在运行期切换/并行。
2. Calibrator 增加 DataMatrix 标记渲染（CoreImage `CIDataMatrixCodeGenerator` 可生成；注意 macOS 生成器支持、静区手动留白 1 模块）。
3. A/B 基准（用 Phase 0 工具）：同场景双通道各录 5 分钟。切换门槛：**Vision 集齐率 ≥ ArUco 且 σ 不劣化**。
4. `VNSequenceRequestHandler` + `VNTrackObjectRequest` 跟踪层（§2.2）：全量检测 8Hz + 跟踪补间到 30/60Hz。验收：检测 CPU 占用降 ≥50%，输出间隔 p95 ≤ 35ms（60fps 跟踪）。
5. 可选探索（时间盒 0.5 天）：`VNDetectRectanglesRequest` 无标记兜底（§2.3），只出可行性结论，不进主链路。

### Phase 3 — 传输升级（1 天）

1. 新增 UDP 结果通道（Network.framework，独立 Bonjour 服务 `_aimphone-rt._udp` 或同服务 TXT 记录带 UDP 端口）：
   - 二进制格式 `[seq][t][markers][x][y]`，20Hz 定时发送；
   - Mac 端 latest-wins 消费，序号跳变计丢包率，进 CSV。
2. `localAim` TCP 控制帧降级为低频心跳/调试（保留向后兼容，protocol.md 加 §9）。
3. 验收：推送间隔 p50 ∈ [48, 52]ms、p95 < 65ms；丢包率 < 1%（同局域网）。
4. 兜底开关：`includePeerToPeer`（AWDL）与 BLE 坐标通道各留 0.5 天 PoC，只在「无路由器演示场地」需求确认后投入；AWDL 需实测延迟尖峰是否可接受（§3.1 风险）。

### Phase 4 — 路线切换决策（0.5 天评审）

- 对照 Phase 0 基线出报告：若路线 A（手机识别）集齐率/σ 达标 → 视频推流改为按需（仅调试开），ADR-001 正式推翻，写 ADR-007；
- 不达标 → 保持 Mac 识别，仅落 UDP 双通道 + Phase 1 质量改进，延迟收敛到 ~60–80ms。

---

## 5. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| Vision 大倾角漏检 | 主通道不可用 | ArUco 回退通道并行运行，门槛不达标不切 |
| 8 标记占屏幕空间 | UI 遮挡投诉 | 中点标记可选 16pt 小尺寸；Calibrator 已支持 `--marker-size` |
| AWDL 延迟尖峰（50–100ms 周期） | 恰落在推送目标区间，抖动超标 | 默认走基础设施 Wi-Fi；p2p 仅作开关 |
| iOS 26 MPC 弃用/无网络场景坏掉 | 兜底方案失效 | 不依赖 MPC，用 Network.framework 自建 |
| BLE 吞吐 iOS 侧回落（400–600kbps） | 视频永远不可行 | BLE 只承载坐标小包 |
| DataMatrix 生成器限制 | 标记生成受阻 | `CIFilter CIDataMatrixCodeGenerator` 双端可用（iOS 13+/macOS 10.15+），风险低；兜底为内嵌 8 张预生成 PNG |

## 6. 关键外部依据（检索于 2026-08-16）

- Apple Developer：`VNDetectBarcodesRequest` 文档（多条码/帧、symbology 白名单、Revision 3）；WWDC24 Session 10163（Vision Swift API、跨帧跟踪、限制 symbology 提速）
- Dynamsoft 条码基准（2026-07）：Vision/MLKit ~96–98ms/图（全格式静态图最差情形）、Vision 难样本漏检过半 → 回退通道必要性
- it-jim iOS 扫码对比（2025-02）：Vision 静态图 ~70ms、支持多码/ROI/白名单
- FMAC 基准（arXiv:2601.07723，2026-01）：ArUco/AprilTag/STag/TopoTag 精度与检出率对比
- BLE 吞吐：Apple Forums 770717（iOS 实测 400–600kbps）；EDN/NovelBits（2M PHY+DLE 理论 1.4Mbps、连接间隔 7.5ms 起、iOS 重协商至 15–30ms）
- AWDL/MPC：Meter（2022，AWDL 造成 50–100ms 延迟尖峰）；Ditto 跨平台 P2P 分析（AWDL 160–320Mbps、BLE 辅助发现）；Stormo（2026-07，MPC iOS 26 弃用、QUIC 替代、33fps P2P 相机预览实证）
- MQTT/CoAP 延迟：MDPI Applied Sciences 11(11):4879（2021，局域网 TTC 最小 7.27ms、高频下 MQTT broker 丢包 65%）

---

## 7. 实施细节（文件级改动清单）

> 行号基于 2026-08-16 工作区状态，仅作定位锚点；以符号名为准。
> 所有新文件必须带 L0 文件头（docs/comment-style.md），所有注释中文。

### 7.1 Phase 0 · 测量打点

| 文件 | 改动 |
|---|---|
| `ios/AimPhone/CameraStreamer.swift` `localizeFrame`（约 L460） | 检测前后取 `CFAbsoluteTimeGetCurrent()`，差值作为 `detectMs` 并入 localAim JSON |
| `Sources/ScreenAim/main.swift` `Calibrator.logLocalAim`（约 L605） | CSV 头改 `timestamp,markers,ids,x,y,detect_ms,src`；签名加参数；旧 CSV 不再写入（新会话新文件，无需兼容） |
| `Sources/ScreenAim/main.swift` `ScreenSampler.processJPEG/processBGRA` | 检测耗时打点，FPS 日志行追加 `det=xxms` |

注意：**跨设备端到端延迟不做硬时钟同步**，Phase 0 只测 Mac 侧管线分段耗时 + 推流到达间隔；
端到端数字在 Phase 3 UDP 包带发送时间戳后才有意义（假设同局域网 NTP 误差 <10ms，须在报告注明）。

### 7.2 Phase 1.1 · 冗余标记 + 最小二乘单应

1. `Calibrator.rebuildMarkers`（约 L644）：`newCenters` 扩为 8 项——四角 id0–3 保持不动，
   新增边中点 id4–7：上中 `(W/2, m+s/2)`、右中 `(W-m-s/2, H/2)`、下中 `(W/2, H-m-s/2)`、左中 `(m+s/2, H/2)`；
   生成循环 `0..<4` → `0..<8`（DICT_4X4_50 共 50 个 id，够用）。
2. `screenCornerMap` 两处赋值（init 约 L785、滑杆回调约 L921）同步为 8 项；
   calib 下发 JSON（protocol §6）的 `markers` 字段与 `screenCornerMap` 同源，自动带 8 项，协议格式不变。
3. `Sources/ScreenAimCore/Homography.swift` 新增：
   ```swift
   /// RANSAC 单应：≥4 点鲁棒求解。迭代 50 次随机抽 4 用四点 DLT，
   /// 重投影误差 < thresholdPx 记内点；最优内点集 ≥4 才成功，内点上最终重解。
   public init?(ransacSrc src: [CGPoint], dst: [CGPoint],
                thresholdPx: Double = 2.0, maxIter: Int = 50)
   ```
   内点数 >4 时的最终精化用 Accelerate（iOS/macOS 双端系统框架，零依赖）：
   `import Accelerate`，对 2N×9 的 A 阵求 AᵀA（9×9 对称）最小特征向量（`dsyev_`）。
   纯 Swift SVD 不自造轮子。
4. `ScreenLocalizer.localize`：`guard screenCornerMap.count == 4` → 收集匹配点对，
   `matched.count >= 4` 即求解（优先 RANSAC 入口）；`screenCornerMap` 语义变为"≥4 项"。
5. Mac 端 `OpenCVBridge` 新增 `mapPointRANSAC:src:dst:success:`（`cv::findHomography(s, d, cv::RANSAC, 3.0)`），
   `ScreenSampler.processBGRA` 改用它；`screenCornerMap.count == 4` 的 guard 同步放宽为 ≥4。

**验收**：`swift run ScreenAim --self-test` 通过（自检场景补 8 标记）；
人为遮挡任一边角标记输出不中断；遮挡任意两个不相对标记，自检映射误差 < 2pt。

### 7.3 Phase 1.2 · iPhone 亚像素角点精化

- `MarkerDetector.decode` 内 `pts` 定序后、解码前调用新增的 `refineCorners(_:w:h:)`：
  对四边各取 12 个采样点，沿边法向 ±5px 双线性采灰度（复用 `sampleGray`），
  梯度最大位置做加权质心得亚像素边缘点 → 12 点 TLS 直线拟合 → 相邻直线求交得精化角点。
- `// NOTE:` 注明动机：极值角点来自暗组件像素中心，系统性偏内 ~0.5px，精化同时修正该偏移。
- **验收**：24pt 标记静止场景，帧中心 σ 从 ~0.05pt 进一步下降或持平（1280w），且 20pt 标记命中率显著提升（当前 ~0%）。

### 7.4 Phase 1.3 · One Euro Filter

- 新文件 `Sources/ScreenAimCore/OneEuroFilter.swift`：标准实现，参数 `minCutoff=1.0, beta=0.5, dCutoff=1.0`（L2 注释给调参指南）。
- `ScreenLocalizer` 内嵌 x/y 两个实例，在 `localize` 输出前滤波；连续 10 帧无 aim 后首帧重置滤波器。
- Mac 端 ScreenCaptureKit 路径同样接入（`ScreenSampler` 输出侧；先确认 `Package.swift` 中
  ScreenAim target 是否已依赖 ScreenAimCore，没有则添加）。
- **验收**：静止 σ 降 ≥50%；快速横扫无肉眼可见滞后。

### 7.5 Phase 2.1 · Vision DataMatrix 检测器

1. 新文件 `Sources/ScreenAimCore/VisionMarkerDetector.swift`：
   - 与 `ArucoDetector` 对等的 `detect(bgra:width:height:bytesPerRow:) -> [DetectedMarker]`；
     内部用 `CVPixelBufferCreateWithBytes`（`kCVPixelFormatType_32BGRA`）包装裸指针喂 Vision；
     另加 `detect(pixelBuffer:)` 重载（iPhone 的 `localizeFrame` 有原生 CVPixelBuffer，零拷贝）。
   - `VNDetectBarcodesRequest`，`symbologies = [.dataMatrix]`；解析 `payloadStringValue`
     形如 `"aim:N"` → id=N；中心 = 四角点均值。
   - **WARNING 注释**：Vision 坐标归一化且**左下原点**，须 `y = (1 - y) × height` 翻转。
2. `ScreenLocalizer` 增加 `detectorKind: .aruco / .vision / .both`；`.both` 为 A/B 模式，
   两路结果都进 localAim JSON（`visionMarkers/visionX/visionY`）与 CSV。
3. Calibrator 标记生成：DataMatrix 用 `CIFilter CIDataMatrixCodeGenerator`（message `"aim:N"`，
   双端可用）；静区 1 模块，现有白卡 pad 已覆盖；位图按 `backingScaleFactor` 生成（与 ArUco 路径一致）。
   `--make-markers` 加 `--kind datamatrix` 选项。
4. **A/B 门槛**：同一场景各录 5 分钟 CSV，Vision 集齐率 ≥ ArUco 且中心 σ 不劣化 → 主通道切换，
   写 ADR-012；不达标则 Vision 仅留作并行校验，ArUco 保持主通道。

### 7.6 Phase 2.2 · VNTrackObjectRequest 跟踪层

- 新文件 `Sources/ScreenAimCore/MarkerTracker.swift`：
  - 持有一个 `VNSequenceRequestHandler`（非线程安全，遵守"串行队列使用"的既有线程约定）；
  - 全量检测成功后，为每个标记建 `VNTrackObjectRequest(detectedObjectObservation:)` 播种；
  - 中间帧只跑 track；`observation.confidence < 0.7` 或距上次全量 >150ms → 触发全量重检。
- 节奏：全量 8Hz + 跟踪补间到相机帧率；输出每帧都有。
- **验收**：检测耗时均值降 ≥50%；输出间隔 p95 ≤ 35ms（30fps 相机）；连续遮挡 300ms 内恢复。

### 7.7 Phase 3 · UDP 结果通道

1. **协议（protocol.md 新增 §9）**：
   - Mac 的 `_aimphone._tcp` Bonjour 服务 TXT 记录加 `udpport=9101`（不新增服务类型）；
   - Mac 起 `NWListener(using: .udp, on: 9101)`。
   - 包格式 25B 全大端：`u32 seq | u64 sendMs | u8 markers | f32 x | f32 y | u8 flags`（flags bit0 = hasAim）。
2. iPhone `CameraStreamer`：`DispatchSourceTimer` 50ms 周期，取最新识别结果组包发送；
   未集齐也发心跳（flags=0）；TCP 的 localAim 控制帧降为 1Hz 调试副本（向后兼容保留）。
3. Mac `main.swift` 新增 `AimResultUDPListener`：接收 → seq 跳变累计丢包率 → 走与 `onAim` 相同的消费链 →
   CSV（`src=udp`）；手机发送时间戳对 Mac 接收时间戳得 e2e_ms（标注 NTP 假设）。
4. **验收**：推送间隔 p50 ∈ [48, 52]ms、p95 < 65ms；同局域网丢包率 < 1%；
   `swift run ScreenAim --calibrate --serve 9100` 全链路人工回归。
5. 兜底 PoC（各 0.5 天，只在演示场地确认无路由器后投入）：
   `NWParameters.includePeerToPeer = true`（AWDL，须实测 50–100ms 尖峰是否可接受）；
   BLE 坐标通道（CoreBluetooth，Mac 端 central / iPhone peripheral，notify 20Hz）。

### 7.8 文档同步清单（随代码同提交）

- 新增决策：`docs/decisions.md` 追加 ADR-007（冗余标记 + RANSAC）、ADR-011（控制信道
  Codable enum 类型化）、ADR-012（Vision 双通道结论）、ADR-013（UDP 双通道）；
  推翻 ADR-001 时写清触发条件已满足。
  （原计划的 ADR-008/009 编号已被 decisions.md 中鼠标/上报决策占用，顺延为 012/013。）
- `docs/protocol.md` §9（UDP）；`docs/architecture.md` 模块表加 VisionMarkerDetector / MarkerTracker / OneEuroFilter / AimProtocol；
- `docs/modules.md` 公开 API 索引更新；`docs/README.md` 文档地图加本方案；
- 根 `README.md` 实测表更新（新命中率/σ/延迟数字，注明条件）。

### 7.9 Phase 1.4 · 控制信道 Codable enum 类型化

> 原则：**线上格式零变化**——只把两端内部的 `[String: Any]` + 魔法字符串换成强类型，
> encode 出的 JSON 与 protocol.md 现有示例逐字段一致（只加不删、向后兼容原则不变）。

**信号盘点（闭集字符串 → enum，代码锚点见括注）**：

| 信号 | 闭集取值 | 现状锚点 |
|---|---|---|
| iPhone→Mac 控制帧 `type` | togglePairingQR / localAim / disconnect / mouseDown / mouseUp / mouseClick / mouseScroll | protocol §7/§8；`CameraStreamer.sendControl` 各调用点；`main.swift` `server.onControl` switch |
| Mac→iPhone 控制帧 `type` | calib / pairingQR / captureStart / captureStop | protocol §6/§10；`CameraStreamer.handleControl`；`Calibrator`/`FrameServer.sendControl` 各调用点 |
| 鼠标 `button` | left / right / middle / all（all 仅 mouseUp 兜底） | `main.swift postMouseCGTypes` 字符串 switch |
| 采集回传 `kind` | session / frame / end | protocol §10；`CameraStreamer.sendCaptureRecords`；`CaptureServer.processRecord` |
| localaim CSV `src` | tcp（Phase 3 起加 udp） | `Calibrator.logLocalAim` |
| mouse CSV `event` | down / up / click / scroll | `Calibrator.logMouseEvent` |
| 检测器种类（Phase 2 用） | aruco / vision / both | 方案 §7.5 `detectorKind`，本次只建类型不接逻辑 |

**不改 enum 化的部分**：二维码配对 payload `{"host","port"}` 是开放结构体（可作 Codable struct，
非 enum）；calib `markers` 键集随标记布局扩展，保持开放字典；视频帧二进制不动。

**文件级改动**：

| 文件 | 改动 |
|---|---|
| `Sources/ScreenAimCore/AimProtocol.swift`（新增，L0 文件头） | 见下方类型清单 |
| `Sources/ScreenAim/main.swift` | `FrameServer.sendControl` 改收 `MacToPhoneMessage`；`server.onControl` 分发改解码 `PhoneToMacMessage` 后 switch 枚举；`CaptureServer.processRecord` 的 `kind` switch 换 `CaptureRecordKind`；`logLocalAim` 的 `src:` 参数换 `AimSource`；`logMouseEvent` 的 `event:` 换 `MouseEventKind`；`postMouse*` 的 button 字符串入参换 `MouseButton` |
| `ios/AimPhone/CameraStreamer.swift` | `sendControl` 改收 `PhoneToMacMessage`；`sendMouseDown/Up/Click/Scroll`、`toggleMacPairingQR`、`localizeFrame` 上报、`disconnect` 全部改构造枚举；`handleControl` 改解码 `MacToPhoneMessage`；采集上传 session/end 记录的 `kind` 用 `CaptureRecordKind` |
| `ios/AimPhone/CaptureRecorder.swift` | meta.jsonl 行内 `kind` 字段（如有）同源换枚举 rawValue |

**`AimProtocol.swift` 类型清单**：

1. `enum MouseButton: String, Codable { case left, right, middle, all }`
2. `struct LocalAimReport: Codable`：`markers:Int / detected:[Int] / missing:[Int] / x:Double? / y:Double? / detectMs:Double`，CodingKeys 保线上键名 `detect_ms`
3. `enum PhoneToMacMessage: Codable`：`togglePairingQR / localAim(LocalAimReport) / disconnect / mouseDown(MouseButton) / mouseUp(MouseButton) / mouseScroll(Int) / mouseClick(MouseButton)`（mouseClick 为旧协议保留）。
   自定义 `encode(to:)`/`init(from:)`：`type` 字符串与 protocol §7/§8 逐字一致；
   **未知 type 解码返回 nil 而非 throw**（保持"旧端忽略未知消息"的兼容语义，调用点 `if let` 即可）
4. `enum MacToPhoneMessage: Codable`：`calib(screenW:Double, screenH:Double, markers:[String:[Double]]) / pairingQR(visible:Bool) / captureStart(seconds:Int, fps:Int, label:String) / captureStop`。
   **WARNING 注释**：markers 必须保持 `{"0":[x,y],…}` JSON 对象形态——Foundation 的
   `[Int:…]` 字典键会编成 JSON 数组，直接破坏 §6 线上格式；故键保 String 或写自定义编码
5. `enum CaptureRecordKind: String, Codable { case session, frame, end }`
6. `enum AimSource: String, Codable { case tcp, udp }`（udp 为 Phase 3 预留值）
7. `enum MouseEventKind: String, Codable { case down, up, click, scroll }`
8. `enum DetectorKind: String, Codable { case aruco, vision, both }`（Phase 2 用，仅建类型）

**兼容陷阱（自检必须覆盖）**：
- `JSONSerialization` → `JSONDecoder` 后 NSNumber 桥接消失：旧代码 `as? Int` 对 JSON `1.0`
  能过，`Decoder` 的 `Int` 对 `1.0` 会失败——encode 侧保证整数键按 Int 编码
- `mouseUp button:"all"` 的兜底语义、`mouseClick` 旧消息受理保持不变
- iPhone 端 `sendMouseClick` 保留（旧协议路径），新 UI 不调用——现状不变

**验收**：
- `--self-test` 新增场景：全部消息 encode→decode round-trip；protocol.md §6/§7/§8/§10
  内嵌示例 JSON 作为固定样本字符串 decode 成功且字段值全对；反向 encode 与样本逐字段一致
  （key 顺序不计）
- `swift build && swift run ScreenAim --self-test`；iOS 侧 `xcodegen generate && xcodebuild` 编译过
- 真机冒烟一轮：配对 → calib 下发 → 鼠标三键 + 滚轮 → 采集 10 秒回传 → 主动断开，
  两端日志与 CSV 列值与改动前一致
- 新增 ADR-011（控制信道 Codable enum 类型化：决策 = 双端共享 AimProtocol.swift +
  自定义编解码保线上格式；推翻条件 = 协议改二进制编码如 UDP 包后 JSON 信道退役）
