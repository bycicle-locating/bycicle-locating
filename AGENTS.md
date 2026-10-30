# AGENTS.md

给 AI 代理与新协作者的仓库工作约定。

`CLAUDE.md` 是指向本文件的**符号链接**（Windows 上创建软链需开启开发者模式）。
**内容只维护这一份**，不要在两处分别编辑。

## 1. 这是什么

自行车定位与骑行记录产品，三层单体仓库：

| 目录 | 角色 | 技术栈 | 状态 |
|---|---|---|---|
| `app/` | 手机端：绑定、地图、骑行记录 | Flutter + Riverpod + go_router | 骨架，无插件接入 |
| `firmware/` | 车载硬件：采样、离线缓存、上报 | ESP-IDF v5.x (C) + NimBLE | 骨架，硬件模块为桩 |
| `backend/` | 云端：MQTT 接入 + HTTP API | Go 1.22，**当前只用标准库** | 骨架，内存存储 |
| `docs/` | 契约与设计 | Markdown | **跨端唯一真相** |

硬件（**已实测**，见 `docs/hardware.md` §0）：**ESP32-S3**（8 MB flash / 带 PSRAM）+ Quectel **EC800MCNGB**
（Cat.1，GNSS 可用）+ NTAG215 NFC 标签 + IMU。板上当前跑的是 **MicroPython v1.29.0**，不是本项目固件。

**当前处于 M0**：接口与文档齐全，业务逻辑与硬件驱动未实现，见 `docs/roadmap.md`。

## 2. 命令

> **验证状态（2026-10-30）**
> - `backend/`：✅ `go build` / `go vet` / `go test` / `gofmt -l` 全过（`golang:1.22` 容器），
>   绑定接口冒烟覆盖 200 / 409 / 403 / 401。
> - `app/`：✅ `flutter analyze`（0 issue）、`flutter test`（8 项）、`dart format` 全过（Flutter 3.44 容器）。
>   ⚠️ 但**没有 `android/`、`ios/` 平台目录**，还不能打包——需先 `flutter create`（见 app/README）。
> - `firmware/` 纯 C 模块（`app_types` / `proto_encode` / `ringbuf` / `uploader`）：✅ gcc 13 编译 + 主机单测通过。
> - `firmware/` 的 ESP-IDF 部分（`main.c`、`modem/`、`ble/`、`power/`）：⛔ **尚未编译验证**。
> - **硬件 bring-up 已通过**（2026-10-30）：ESP32-S3 + EC800MCNGB，SIM READY、信号 31、网络已注册、
>   GNSS 可开启；UART 为 GPIO17(TX)/GPIO16(RX)。详见 `docs/hardware.md` §0。
> - 本机没有 Go / Flutter / ESP-IDF，但有 Docker：可用 `golang:1.22`、`ghcr.io/cirruslabs/flutter:stable`、
>   `gcc:13` 三个镜像完成验证，不必装本地工具链。ESP-IDF 仍需本地安装或专用镜像。

```bash
# 后端
cd backend
go build ./... && go vet ./... && go test ./...
APP_ENV=dev DEV_SEED_CLAIM=7QK2M5XJ4TZP6RWN go run ./cmd/server   # 无需 DB/broker
docker compose up -d                                            # 本地 mosquitto + postgres

# 手机端
cd app
flutter pub get && flutter analyze && flutter test
dart format --set-exit-if-changed .

# 固件
cd firmware
. $IDF_PATH/export.sh
idf.py set-target esp32s3 && idf.py build
```

**验证诚实原则**：没跑过的命令不要说跑过了；没编译过的代码不要声称可用。改动后如果因为缺工具链无法验证，在总结里明说。

## 3. 架构边界（改代码前必读）

### 3.1 契约优先

跨端只有一个强耦合点：**协议**。任何字段改动必须按顺序：

1. 先改 `docs/protocol.md`（设备↔云）或 `docs/pairing.md`（App↔设备）；
2. 不兼容变更（改单位、改语义、加必填、删字段）→ 提升 `v` 并新增 `v2/` 主题前缀；
3. 再改三端实现：固件 `main/proto` → 后端 `internal/protocol` → App `core/api` + 模型；
4. 同一个 PR 内完成，PR 描述贴协议 diff。

**已定死的语义**（改它们要写 ADR）：
- 时间一律 UTC RFC3339；**排序只信 `seq`，不信设备时钟**。
- `seq` 是设备级单一单调计数器，**每个轨迹点各占一个号**，因此 `(deviceId, seq)` 全局唯一。
- 单位：位置 m、速度 **m/s**、航向度、海拔米。km/h 只在 UI 出现。
- 坐标一律 WGS-84；转 GCJ-02 只在 App 展示层。

### 3.2 固件

- **AT 指令字符串只允许出现在 `main/modem/`**。其它模块调 `modem_*` 接口。
- 采样路径**不得阻塞**在 AT 或网络；上报由独立任务驱动。
- **先持久化 `seq` 再用它**；深度睡眠会清 RAM，唤醒后从 NVS 恢复 `seq` 与缓冲元数据。
- **发布成功才 `commit`** 缓冲；宁可在线上重传，也不能删掉未发出的点。
- 睡眠前必须主动发布 `online:false`——broker 的遗嘱只在异常断开时触发（protocol.md §2.2）。
- `CONFIG_NEWLIB_NANO_FORMAT=y`，**`printf` 不支持 `%f`**；全部用整数定点格式化（见 `proto_encode.c`）。
- `main.c` 目前用 **RAM 后端**跑 ringbuf，休眠即丢数据；M1 换成 `track` 分区上的 LittleFS。

### 3.3 后端

- handler 只做：鉴权 → 解码 → 调 service → 编码。**不许写业务判断**。
- **SQL 只出现在 `store` 实现里**；接口不得暴露 `pgx`/`sql.Row`。
- **幂等靠主键**：`INSERT ... ON CONFLICT (device_id, seq) DO NOTHING`，不做"先查再插"。
- 绑定必须**原子**：校验声明码 + 烧毁 + 写车主在同一次写操作内（data-model.md §3）。
- 新增依赖前先想清楚：当前骨架零依赖，`go build ./...` 不联网即可通过。
- `APP_ENV=prod` 会在缺 JWT 时**拒绝启动**——这是有意为之，别为了"跑起来"绕过它。

### 3.4 手机端

- **feature-first**：`features/<name>/{data,domain,presentation}`；跨 feature 只经 `core/`。
- **widget 不发请求**：网络调用只在 `data/` 或 provider，页面 `watch` provider。
- 错误统一成 `ApiException`，UI 不认识 `DioException`。
- 禁止裸 `print`（linter 已开 `avoid_print`），用 `core/log.dart`。

### 3.5 安全红线（违反即为缺陷，不是风格问题）

1. **绑定必须由后端核验声明码**。NFC 只提供"在场证明"，BLE 连接不授予任何权限。
2. **BLE 与 RSSI 不得用于布防/撤防或任何授权判定**，只做 UI 提示（需滞回 + 去抖）。
3. **解绑只能由车主账号在服务端发起**。设备长按只清本地状态，绝不清服务端绑定。
4. 声明码是 16 位 Base32（字母表 `A-Z2-7`，**不含 0/1/8/9**），后端只存带 pepper 的 HMAC 哈希。
   绑定后**不要删哈希**：先校验码、再判 `claimed_at`，否则会向任何知道 deviceId 的人泄露车辆注册状态。
5. 对外错误不得泄露设备是否存在：声明码错误与设备不存在返回同一个 403。
6. MQTT 必须 TLS + 每设备独立凭据 + ACL 只能读写自己的主题；载荷上限 4 KB。
7. 报文校验三层都要做：主题白名单、载荷校验、**主题设备 ID 与载荷设备 ID 必须一致**。

## 4. 编码约定

- **Go**：`context` 首位；错误用 `%w` 包装；日志用 `slog`（不要 `fmt.Println`）；不用 ORM。
- **Dart**：显式返回类型；`const` 优先；模型手写（暂不引代码生成）；单位换算只在展示层。
- **C**：`esp_err_t` 返回错误码；结构体用定点整数表示物理量；回调/中断里不阻塞、不分配内存。
- **注释**：只写代码表达不了的约束（为什么这样、不能怎样）。不写"这行做了什么"。
- **提交**：`<type>(<scope>): <中文简述>`，见 `CONTRIBUTING.md`。
- **合并**：`main` 受**服务端强制**保护——开分支 → 推分支 → PR → 三个检查全绿 → squash 合并。
  `enforce_admins=true`，管理员直推也会被 `GH006` 拒绝，没有本地可绕过的开关。
  应急时才由管理员临时停用保护，见 `CONTRIBUTING.md` §1.1。

## 5. 已知坑

| 坑 | 说明 |
|---|---|
| **板子是 ESP32-S3** | 经典 ESP32 的引脚表在这里会翻车：GPIO19/20 是原生 USB，GPIO22–25 **不存在**，GPIO26–34 被 flash/PSRAM 占用，ADC1 只在 GPIO1–10，strapping 脚是 0/3/45/46 |
| 板上现有固件是 MicroPython | 烧写 ESP-IDF 固件会覆盖它，`scripts/*.py` 那套 bring-up 手段随之失效；反过来，bring-up 阶段它是最快的验证路径 |
| **设备在运营商 CGNAT 之后** | 实测模块拿到 `10.43.x.x` 私网 IP，**后端永远无法主动连设备**。一切下行只能靠 broker 中转（设备订阅自己的 `cmd` 主题），不要设计"后端直连设备"的功能 |
| EC800M GNSS 选配 | 实测 SKU `EC800MCNGB` 支持 GNSS（`AT+QGPS=1` → OK）；`LC/LE` 不带。室内 `AT+QGPSLOC?` 返回 `CME ERROR: 516` 是"未定位"而非故障 |
| EC800M MQTT 是 AT 栈 | `AT+QMTOPEN/CONN/PUBEX`，URC（`+QMTRECV`）会插在回显中间，必须按行解析 |
| `AT+QMTPUBEX` 两段式 | 先发指令等 `>`，再发裸数据；不能用一次阻塞命令搞定 |
| 主动断开发不出遗嘱 | 睡眠前自己发 `online:false`，否则后端一直显示在线 |
| Cat.1 上行约 5 Mbps | 按流量计费；单批 ≤ 60 点、≤ 4 KB |
| NFC 标签可克隆 | 靠"一次性声明码"降低危害；升级路径 NTAG 424 DNA（ADR-0003） |
| BLE 分片 | 单次写入默认 20 字节；Android 要主动协商 MTU，iOS 行为不同 |
| RSSI 抖动 | 必须滞回（-65/-78 dBm）+ 连续 3 采样去抖 |
| 深度睡眠清 RAM | `seq`/缓冲元数据必须落 NVS 或 RTC 内存 |
| Flutter 缺平台目录 | `app/` 尚无 `android/`、`ios/`，不能打包；先 `flutter create --platforms=android,ios --org <你的域名> --project-name bkl_app .` |
| Windows 软链 | `CLAUDE.md` 是指向 `AGENTS.md` 的符号链接（仓库已设 `core.symlinks=true`）；未开开发者模式的机器检出时会退化成普通文件，需开启后 `rm CLAUDE.md && MSYS=winsymlinks:nativestrict ln -s AGENTS.md CLAUDE.md` |

## 6. 改这些之前先读文档

| 要改的东西 | 必读 |
|---|---|
| 报文字段、主题、QoS | `docs/protocol.md` |
| 绑定、解绑、BLE 特征 | `docs/pairing.md`、`docs/adr/0003-nfc-binding.md` |
| 表结构、索引、骑行切分 | `docs/data-model.md` |
| 引脚、外设、功耗 | `docs/hardware.md` |
| 模块职责与 seam | `docs/architecture.md` |
| 分支保护规则、必需检查 | `docs/branch-protection.md` |
| 技术选型理由 | `docs/adr/` |

## 7. 不要做的事

- 不要把业务逻辑（轨迹切分、里程、围栏、告警升级）放进固件——改不动，得 OTA。
- 不要用 BLE 传轨迹或做授权。
- 不要在 `store` 之外写 SQL，也不要在 handler 里做业务判断。
- 不要为了"跑通"放宽安全边界（开发鉴权、无 TLS、无限流）。
- 不要新增顶层目录来放单个文件；三层结构是有意保持的。
- 不要删除或伪造测试来让流水线变绿。
