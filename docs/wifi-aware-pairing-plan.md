# Wi-Fi Aware 配对替代扫码实施方案（iOS 26 / macOS 26+）

> 状态：**已并入 [transport-26-plan.md](transport-26-plan.md)**（2026-08-17 按"全部署机
> iOS 26/macOS 26+"前提复审合并，Wi-Fi Aware 定位由第三通道升为首选通道）。
> 本文保留为调研背景，实施以 transport-26-plan.md 为准。
> 前置阅读：[protocol.md](protocol.md) §2/§3（现行 Bonjour 发现 + 扫码配对）、
> [skills/wifi-aware-pairing](../skills/wifi-aware-pairing/SKILL.md)（API 指南）、
> [tlv-migration-plan.md](tlv-migration-plan.md)（并行方案，协议栈可复用）、
> [comment-style.md](comment-style.md)。

## 1. 问题与结论

**问题**：Wi-Fi Aware 能否替换"扫码绑定 IP 地址"的做法？

**结论：能，但它替代的不止扫码——而是整个"发现+配对"层；且建议定位为第三条通道而非替换主路径。**

先厘清现状（protocol.md §2/§3）：扫码**已经不是主路径**——Bonjour 自动发现才是，
二维码与手工 IP 是 Bonjour 失效时的兜底。所以准确的问题是："Wi-Fi Aware 能否成为新的
零配置通道，把扫码兜底也吃掉？"

| 维度 | 扫码/Bonjour（现状） | Wi-Fi Aware |
|---|---|---|
| 需要同局域网/路由器 | **需要** | **不需要**（NAN 直连，靠近即可） |
| 配对动作 | 每次扫码（兜底时） | 一次性系统配对，此后靠近自动重连 |
| 本地网络授权弹窗 | 有（protocol.md §4 的 5s 看门狗就是为它的卡死而生） | **无**（不走局域网子系统） |
| 加密 | 无（局域网明文） | 强制 datapath 加密 |
| 系统/硬件门槛 | 无 | 双端 26+、iPhone 12+、Mac 原生（Catalyst 不行） |
| API 成熟度 | 十年验证 | iOS 26 初代，论坛已有互通性/稳定性报告 |

**推荐定位**：

```
无路由器/不可信网络场景 → Wi-Fi Aware（新增，首选）
日常局域网场景         → Bonjour 自动发现（现状，不动）
一切失效时             → 二维码/手工 IP（永远保留）
```

## 2. 硬约束（调研确认）

1. **配对强制 + 配对码**：DeviceDiscoveryUI/AccessorySetupKit 系统流程含 pairing code 提示
   （论坛确认）。收益不是"省掉一次交互"，而是"一次配对永久有效 + 无授权弹窗 + 无路由器"。
2. **Mac 侧打包门槛**：Wi-Fi Aware 服务必须声明在 Info.plist——本项目 Mac 端是 SwiftPM
   CLI，**没有 Info.plist**。Mac 做 publisher 需先包成 .app（或在 Xcode 里加原生 target）。
   这是本方案最大的结构性成本，P0 必须先验证。
3. **UI 归属**：配对 UI（DevicePicker/DevicePairingView 是 SwiftUI 视图）放 iPhone 端；
   Mac 端只做 publisher 角色逻辑。
4. **性能模式**：瞄准链路必须 `.realtime` + `.interactiveVideo`，接受功耗代价；
   用 `currentPath?.wifiAware?.performance` 的性能报告做实测依据。
5. **初代 API 风险**：iOS 26.0 已有 ESP32 互通失败、Catalyst 缺失等报告——回退链路是硬要求。
6. **DockKit 兼容无冲突**：Wi-Fi Aware 机型门槛 iPhone 12+ 与 DockKit 门槛一致，不引入新限制。

## 3. 目标拓扑

```
iPhone（AimPhone）                                    Mac（ScreenAim）
┌─────────────────────────────────────────────────────────────┐
│ 配对（一次性）：iPhone 端 DevicePicker（系统 UI）⇄ Mac publisher │
├─────────────────────────────────────────────────────────────┤
│ 传输（配对后，优先级从高到低）：                                  │
│  ① NetworkBrowser(.wifiAware) → NetworkConnection            │
│     协议栈 TLV { TCP() }（复用 tlv-migration-plan 的 V2 服务）    │
│  ② NWBrowser(_aimphone2._tcp / _aimphone._tcp) Bonjour 现状    │
│  ③ 扫码/手工 IP（兜底，永久保留）                                 │
└─────────────────────────────────────────────────────────────┘
```

- Wi-Fi Aware 连上后**就是普通 NetworkConnection**，直接复用 TLV 迁移方案的
  FrameServerV2 消息分发（两方案在协议栈层会师：`TLV { TCP() }`）；
- 服务名：`_aimphone-wa._tcp`，双端 Info.plist 声明；
- 角色：Mac = publisher/listener，iPhone = subscriber/browser（iPhone 发起配对与连接，
  与现状一致）。

## 4. 文件级改动清单

> 所有新文件带 L0 文件头，注释中文（comment-style.md）。

### Mac 端

| 文件 | 改动 |
|---|---|
| `Package.swift` / 打包脚本 | **P0 关键**：ScreenAim 包成 .app（xcodegen 或 swift-bundler），Info.plist 加 Wi-Fi Aware 可发布服务声明 `_aimphone-wa._tcp`；CLI 形态保留为无 Wi-Fi Aware 的降级构建 |
| `Sources/ScreenAim/WifiAwareServer.swift`（新增） | `WACapabilities` 探测；`NetworkListener(for: .wifiAware(...)) { TLV { TCP() } }`；复用 FrameServerV2 的回调面（onFrame/onControl/...）；性能报告定时采样进 CSV |
| `Sources/ScreenAim/main.swift` | `--serve` 追加启动 Wi-Fi Aware listener（能力不满足时打印降级日志）；悬浮层 pill 显示当前链路来源（wa / bonjour / manual） |

### iPhone 端

| 文件 | 改动 |
|---|---|
| `ios/AimPhone/Info.plist`（经 project.yml） | 声明 `_aimphone-wa._tcp` 可订阅服务 |
| `ios/AimPhone/WifiAwareTransport.swift`（新增） | `if #available(iOS 26.0, *)`：`WAPairedDevice.allDevices` 订阅配对表；`NetworkBrowser(.wifiAware)` 发现 → `NetworkConnection` 连接；实现 P2 抽出的 `Transport` 协议（TLV 方案先行） |
| `ios/AimPhone/PairingView.swift`（新增） | `DevicePicker` SwiftUI 封装，入口放设置/连接面板 |
| `ios/AimPhone/CameraStreamer.swift` | 连接策略编排：已配对且 Wi-Fi Aware 可用 → 优先；否则 Bonjour；手动断开语义（suppressAutoConnect）对 Wi-Fi Aware 路径同样生效 |
| `ios/project.yml` | Info.plist 服务声明；部署目标维持 17.0（全部新代码 #available 守卫） |

### 文档

- `docs/protocol.md`：新增 §12「Wi-Fi Aware 通道（发现/配对/传输）」，端口与服务名分配表更新；
- `docs/decisions.md`：新增 ADR（Wi-Fi Aware 定位第三通道而非替换的理由；Mac 打包形态决策）；
- `docs/modules.md`：WifiAwareServer/WifiAwareTransport 条目。

## 5. 阶段计划

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 可行性尖刺**（0.5d，**不过则终止**） | ① 确认真机 iOS 26+ 且 iPhone 12+；② 本机 macOS 26 CLI/包壳 App 里 `WACapabilities.supportedFeatures` 实测；③ 最小 .app 包装验证 Info.plist 服务声明生效 | 三项全过才进 P1；任一不过，本方案归档为"待生态成熟"，扫码兜底维持现状 |
| **P1 配对链路**（1d） | iPhone DevicePicker + Mac publisher；配对、删配对、重连三流程 | 配对一次后杀 App 重开，靠近自动发现并连上；配对码 UX 实测记录（与扫码成本对比写进 ADR） |
| **P2 传输会师**（0.5d，依赖 TLV 方案 P1/P2 已落地） | Wi-Fi Aware 连接接入 FrameServerV2 消息分发；realtime 模式 + 性能报告采样 | 15fps 推流 + 鼠标事件全通；延迟/抖动 CSV 对比 Bonjour 路径不劣化 |
| **P3 编排与降级**（0.5d） | 三通道优先级编排、悬浮层链路指示、手动断开语义对齐 | 拔路由器场景全流程可用；插回路由器自动回 Bonjour（或保持 WA，记录决策） |
| **P4 文档**（0.5d） | protocol.md §12、ADR、modules.md | docs/README.md 检查表全绿 |

**与 TLV 方案的关系**：正交但建议 TLV 先行（P2 依赖其 Transport 协议抽象与
FrameServerV2）；若只做本方案不做 TLV，Wi-Fi Aware 连接内部退回手工分帧也可工作，
只是协议栈写 `TCP()` 而非 `TLV { TCP() }`。

**明确不做**：AccessorySetupKit 路径（那是给配件的）；跨平台（Android）NAN 互通
（ESP32 案例显示生态未稳）；删除 Bonjour/扫码路径。

## 6. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| macOS 26 CLI/包壳 App 无法用 Wi-Fi Aware | 方案不成立 | P0 尖刺先验证，不过即终止归档 |
| 配对码 UX 不比扫码省事 | 收益缩水 | P1 实测对比，结论写 ADR；仍保留"无路由器+免授权弹窗"价值 |
| 初代 API 稳定性（发现失败/断连） | 演示现场翻车 | 三通道编排 + 永远保留扫码兜底；现场演示前真机矩阵实测 |
| realtime 模式功耗 | 长时间使用发热掉电 | 性能报告采样监控；闲置自动回 bulk（若 API 允许切换）或断开 |
| 与基础设施 Wi-Fi 并发时的射频竞争 | 延迟抖动 | P2 性能报告对比实测；劣化则调整优先级编排 |

## 7. 激活提示词

把下面这段原样发给 Agent 即可启动实施：

```
激活 Wi-Fi Aware 配对方案：按 /Users/jup33q/Documents/kimi/screen_aim/docs/wifi-aware-pairing-plan.md
执行，先调用 skills 里的 wifi-aware-pairing 技能（TLV 协议栈细节参考 network-framework-tlv 技能），
从 P0 可行性尖刺开始——先实测 Mac 端包壳 App 的 WACapabilities 与 Info.plist 服务声明，
不过则归档终止；过则逐阶段实施，严格遵守 docs/comment-style.md 注释规范与
docs/README.md 文档同步约定，任何阶段不得删除现有 Bonjour/扫码链路。
```
