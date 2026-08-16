---
name: iphone-linked-dev
description: Agent 在 macOS 上与 iPhone 联动开发：用命令行驱动 iOS 模拟器与真机完成「构建 → 部署 → 观察 → 操作 → 验证」闭环。当用户要求 build/运行/调试 iOS app、在模拟器或真机上安装启动应用、截图录屏验证 UI、自动点按滑动输入、发推送/改定位/授权限做测试、deep link 直达页面，或提到 simctl / devicectl / xcodebuild / idb / WebDriverAgent / iOS 模拟器自动化 / 真机联调 时使用。也用于为 iOS 项目搭建 agent 可驱动的开发-验证循环。
---

# iPhone 联动开发（Agent 驱动 macOS ↔ iPhone）

核心思想：Agent 不依赖肉眼，用「结构化观察 → 精确操作 → 再观察验证」的循环驱动 iPhone（模拟器或真机）。CLI 优先，无需任何 MCP server；有 MCP 生态可叠加（见末尾）。

## 第一步：环境自检

```bash
scripts/ios_env_check.sh
```

输出每条工具链的可用状态。关键判读：

- `simctl` 不可用（本机只装了 CLT，没有完整 Xcode）→ 告知用户需安装 Xcode 并执行一次 `sudo xcodebuild -license accept`；之后重跑自检。
- `devicectl` 不可用 → 同上（Xcode 15+ 自带）。
- 真机路线还差 `idb` / WDA → 按 references/physical-device.md 安装。

## 路线选择

| 目标 | 首选工具链 | 详见 |
|---|---|---|
| 模拟器：生命周期/装 App/截图/推送/定位/权限 | `xcrun simctl`（Xcode 自带，零依赖） | [references/simulator.md](references/simulator.md) |
| 模拟器：UI 点按/滑动/输入/无障碍树 | `idb ui` 或 WebDriverAgent；兜底 kimi-cu 点 Simulator 窗口 | [references/ui-automation.md](references/ui-automation.md) |
| 真机：装 App/启动/日志/进程 | `xcrun devicectl`（Xcode 15+） | [references/physical-device.md](references/physical-device.md) |
| 真机：UI 自动化 | WebDriverAgent（需开发者签名） | [references/physical-device.md](references/physical-device.md) |
| 构建/测试 | `xcodebuild` + 结果过滤 | [references/build-loop.md](references/build-loop.md) |

**默认优先模拟器**：无需签名、可随时 erase 重置、状态栏/定位/推送全可编程。只有相机、推送证书、性能、真实外设等模拟器做不到的场景才上真机。

## Agent 联动要义（重要）

1. **观察双通道**：截图（`simctl io booted screenshot`）给视觉，无障碍树（`idb ui describe-all` / WDA `/source`）给语义。能用 AX 树定位就不用像素坐标；必须用坐标时，坐标从最近一次截图/树读取，**界面一变立即作废重取**（与 kimi-cu 的 index 失效规则同理）。
2. **deep link 直达**：App 注册了 URL scheme 时，`xcrun simctl openurl booted "myapp://products/42"` 一步跳到目标页面，省去多轮点按导航。这是缩短 agent 回路最有效的手段。
3. **状态预设再验证**：测试前先编程化布置环境——`status_bar override`（电量/时间/信号）、`location set`、`privacy grant`、`push` 注入通知——再启动 App 截图验证。
4. **构建噪声过滤**：`xcodebuild` 输出巨大，必须用管道过滤（见 build-loop.md），只把错误/警告摘要放进上下文。
5. **每步可证伪**：安装后 `launch` 看退出码、操作后截图对比、测试看 `xcresult`。不要凭命令"执行成功"就断言 UI 达到预期。
6. **模拟器窗口兜底**：simctl 无 tap 能力；若 idb/WDA 都不可用，用 `kimi-cu` skill 后台点击 Simulator.app 窗口（先 `list_apps` 找 Simulator）。

## 与现有 skill 的协同

- **kimi-cu**：模拟器窗口、Xcode 界面的 GUI 兜底操作。
- **mob-beam-mobile**：Mob/BEAM 项目的设备部署与热推（`mix mob.deploy` 走它自己的链路，不用 simctl）。
- **ios-camera-ui**：相机类 UI 的设计规范；本 skill 负责把改完的 UI 跑起来验证。

## MCP 生态（可选叠加，非必需）

本 skill 全部用 CLI 完成。若用户环境已有 MCP，可替代对应章节：`ios-simulator-mcp`（joshuayoes，idb 系）、`simctl-mcp-server`（纯 simctl 只读+管理）、`mobile-mcp`（mobile-next，WDA 系，跨 iOS/Android 含真机）、`XcodeBuildMCP`（构建+模拟器一体）。装了 MCP 就用其工具名替换本 skill 的命令，工作流不变。
