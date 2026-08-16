# UI 自动化：让 Agent 能"点"iPhone

simctl 管生命周期，**不管触控**。点按/滑动/输入/读无障碍树需要以下三条路之一。

## 路线 A：idb（Facebook，模拟器+真机皆可）

```bash
brew install idb-companion
pipx install fb-idb --python python3.11   # 关键：必须 ≤3.11；Python 3.14 asyncio 改动会让 fb-idb 崩
idb list-targets                           # 确认能识别 booted 模拟器
idb connect <UDID>                         # 连接失败时：idb kill && idb_companion --udid <UDID> &
```

核心命令：

```bash
idb ui describe-all --udid <UDID>          # 整屏无障碍树（JSON：label/frame/坐标），agent 定位元素的主依据
idb ui describe-point <x> <y> --udid <UDID>
idb ui tap <x> <y> --udid <UDID>           # 坐标来自 describe-all 的 frame 中心点
idb ui swipe <x1> <y1> <x2> <y2> --udid <UDID>
idb ui text "要输入的文字" --udid <UDID>     # 先 tap 输入框聚焦
idb ui button home|lock --udid <UDID>
```

工作循环：`describe-all` 找元素 frame → `tap frame 中心` → 重新 `describe-all` 验证。**界面一变，旧坐标作废**。

已知限制：主屏幕/系统弹窗的 AX 树可能为空；复杂多指手势不支持。

## 路线 B：WebDriverAgent（WDA，HTTP 协议，真机 UI 自动化唯一现实选择）

模拟器上启动（免签名）：

```bash
git clone --depth 1 https://github.com/appium/WebDriverAgent.git
xcodebuild -project WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
curl http://127.0.0.1:8100/status        # 返回 JSON 即就绪
```

HTTP 接口（默认 8100 端口）：

| 端点 | 用途 |
|---|---|
| `GET /status` | 健康检查 |
| `GET /source?format=json` | 无障碍树（等价 idb describe-all） |
| `GET /screenshot` | base64 截图 |
| `POST /session` `{"capabilities":{"alwaysMatch":{"bundleId":"com.example.app"}}}` | 建会话并拉起 App |
| `POST /session/:id/actions` | tap/swipe 等指针动作（W3C Actions 格式） |
| `POST /session/:id/element` | 按 accessibility id / predicate 查元素（**优先用元素而非坐标**） |

坑：`-destination` 字符串必须用直引号、设备名要精确；首次跑可能要在 Xcode 里过一次签名授权。

## 路线 C：kimi-cu 兜底（无 idb/WDA 时）

Simulator.app 是普通 macOS 窗口。调 `kimi-cu` skill：`list_apps` 找 Simulator → `get_app_state` 拿截图坐标 → `click(x, y)` / `type_text` / `scroll`。精度不如 AX 树，但零安装。同样遵守"界面变化即重取快照"。

## 三条路选择

- 只操作模拟器、想脚本化 → **idb**
- 要真机 UI 自动化、或已有 Appium 生态 → **WDA**
- 临时救场、不想装东西 → **kimi-cu**
