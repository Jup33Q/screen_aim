# ScreenAim 项目文档

手机瞄准投屏方案（路线 B）的完整项目文档。根目录 `README.md` 是快速上手指南，
本目录承载体系化文档。

## 文档地图

| 文档 | 内容 | 何时读 |
|---|---|---|
| [architecture.md](architecture.md) | 系统架构：数据流、模块划分、线程模型、坐标系约定 | 第一次接触代码 / 改结构前 |
| [protocol.md](protocol.md) | 通信协议：TCP 帧格式、Bonjour 发现、二维码配对 payload | 改网络层 / 写新客户端 |
| [modules.md](modules.md) | 逐文件模块说明与公开 API 索引 | 定位某个功能的实现 |
| [decisions.md](decisions.md) | 关键设计决策记录（ADR）：为什么这么做、推翻过什么 | 准备推翻某个既有设计前必读 |
| [development.md](development.md) | 构建、运行、验证、排错清单 | 搭环境 / 出问题时 |
| [comment-style.md](comment-style.md) | **注释系统规范**：注释分级、模板、标记词、维护约定 | 写/改任何代码前 |
| [positioning-optimization-plan.md](positioning-optimization-plan.md) | 定位算法优化调研与实施方案（Vision/协议/蓝牙，分 Phase 执行） | 执行定位优化任务前 |
| [transport-26-plan.md](transport-26-plan.md) | 传输层整体迁移方案（**已实施**，2026-08-17）：TLV 消息流单连接复用（9100/`_aimphone._tcp`），旧手工分帧链路已拆除；Wi-Fi Aware 通道终止（ADR-012，macOS SDK 不可用） | 执行任何传输层改造前 |
| [tlv-migration-plan.md](tlv-migration-plan.md) | TLV 迁移原方案（已并入 transport-26-plan.md，保留为调研背景） | 查 TLV 调研细节 |
| [wifi-aware-pairing-plan.md](wifi-aware-pairing-plan.md) | Wi-Fi Aware 配对原方案（已并入 transport-26-plan.md，保留为调研背景） | 查 WA 调研细节 |

## 文档维护约定

1. **改代码必查文档**：改动涉及架构、协议、公开 API、设计决策时，同提交更新对应文档。
2. **注释规范见 comment-style.md**：所有源码注释遵循统一分级与标记词体系，
   新增文件必须带标准文件头。
3. **文档与代码同仓同审**：文档错误视为 bug。
4. **实测数据必须标注条件**：性能/命中率数据须注明机型、系统版本、采集分辨率
   （参考根 README 的"标记尺寸实测"表格式）。
