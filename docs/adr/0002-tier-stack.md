# ADR-0002：三层技术栈选型

## 状态

已采纳（2026-10-30）

## 背景

仓库规划阶段需要为三层各定一套技术栈。约束：

- 车载端是电池供电的 ESP32，需要精细控制电源、深度睡眠与 OTA；模组 EC800M 用内置 AT 栈跑 MQTT。
- 云端只需处理设备上报与为 App 提供数据，是典型 I/O 密集型服务，长期低负载运行、希望部署简单。
- 手机端要同时支持 iOS 与 Android，需要地图、BLE、NFC 三项能力。
- 团队规模小，维护三种语言已经是上限。

## 决策

| 层 | 选择 | 理由 |
|---|---|---|
| 固件 | **ESP-IDF (C)** | 对 PSM/eDRX 电源管理、分区表、OTA 回滚、看门狗的控制最直接；量产可控性高于 Arduino 层。代价是样板代码多，用 Kconfig 与菜单配置降低重复。 |
| 后端 | **Go** | 单二进制部署（含前端静态资源与迁移），常驻内存低；标准库 `net/http` + `encoding/json` 已够用，MQTT 只加一个 paho 依赖。 |
| 手机端 | **Flutter + Riverpod + feature-first** | 一套代码覆盖双端；Riverpod 不依赖 `BuildContext`、便于单测；按 feature 分目录便于长期演进。 |

配套决定：

- **传输用 MQTT（EC800M 内置栈）**，不自建 HTTP 长轮询。理由：模组原生支持、QoS1 至少一次投递、retained 状态与 LWT 天然满足"离线判定"，
  且下行指令走同一连接，不必另开通道。
- **后端骨架只用标准库**，MQTT 客户端通过接口注入（`internal/mqtt` 定义 `Publisher`/`Subscriber`）。
  这样 `go build ./...` 无需下载依赖即可跑通，也便于用假实现单测 ingest。

## 后果

- 三种语言意味着协议字段要在三处手写解析；缓解手段是 `docs/protocol.md` 作为唯一契约 + `internal/protocol` 的校验测试作为基准。
- 固件迭代慢（需实测功耗），因此**业务逻辑一律放后端**：轨迹切分、围栏判定、告警升级都在 Go 侧，改规则不必 OTA。
- Go 骨架初期没有 ORM；SQL 集中在 `store` 实现里，先手写，等查询复杂到 20 条以上再评估 `sqlc`。
- Flutter 依赖 BLE/NFC 原生插件，后续升级 Flutter 大版本时需重点回归 `flutter_blue_plus` 与 `nfc_manager`。

## 替代方案

- **固件用 PlatformIO + Arduino**：原型更快，但深度睡眠与 OTA 的分区控制较弱，量产阶段大概率要迁回 IDF。
- **固件用 MicroPython**：功耗与稳定性不满足电池长期在线。
- **后端用 FastAPI(Python)**：团队有经验，但生产部署需要额外进程管理，且与固件/App 的类型对齐没有优势。
- **后端用 Node/TypeScript**：本机已有 Node，但常驻内存与部署复杂度高于 Go 单二进制。
- **HTTP 上报代替 MQTT**：需额外实现离线判定与下行通道，反而更复杂。
