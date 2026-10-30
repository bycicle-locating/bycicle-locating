# 硬件设计

> 引脚与功耗**已按实测板子校正**（2026-10-30）。功耗预算仍是估算，待实测。

## 0. 当前 bring-up 状态（实测记录）

| 项 | 实测值 | 来源 |
|---|---|---|
| 主控 | **ESP32-S3**（ROM `esp32s3-20210327`） | `scripts/serial-diag.ps1` 抓启动日志 |
| Flash | **8 MB**（8388608 字节） | `esp.flash_size()` |
| PSRAM | 可用堆约 2 MB，**疑似带 PSRAM**（未看模块丝印确认） | `gc.mem_free()` |
| MAC | `10:bd:a3:**:**:**`（后三位已打码） | `machine.unique_id()` |
| 板上现有固件 | **MicroPython v1.29.0**（不是本项目固件） | 启动横幅 |
| 蜂窝模组 | Quectel **EC800MCNGB**，固件 `EC800MCNGBR06A08M08` | `ATI` |
| SIM | `AT+CPIN?` → `READY` | AT 探测 |
| 信号 | `AT+CSQ` → `31,99`（满格） | AT 探测 |
| 网络注册 | `AT+CREG?` / `AT+CGREG?` → `0,1`（已注册，含数据域） | AT 探测 |
| GNSS | `AT+QGPS=1` → `OK`；`AT+QGPSLOC?` → `CME ERROR: 516`（室内未定位） | AT 探测 |
| UART 接线 | TX=GPIO17、RX=GPIO16、115200 8N1，**已跑通** | `scripts/at-probe.py` |
| 模组供电 | 5 V（板载稳压），`PWRKEY` **未接也能自启** | 实测 |
| APN / 网络 | `CMNET`；`TDD LTE`、`46000`、`LTE BAND 40`；`AT+CGATT?` → 1 | `scripts/net-probe.py` |
| 数据链路 | `AT+QIACT=1` → OK；IP **`10.43.116.225`** | 同上 |
| 外网 DNS | `www.baidu.com` → `36.152.44.132` | 同上 |
| PSM | `AT+CPSMS?` 返回网络下发的 T3324/T3412，模组支持 PSM | 同上 |

> **⚠️ CGNAT 约束（影响架构，不只是硬件）**：模块拿到的是 `10.43.x.x` 私网地址，
> 运营商 NAT 之后**后端无法主动连接设备**。所有通信必须由设备主动发起（MQTT 出站），
> 这也正是 `docs/protocol.md` 采用 MQTT 发布/订阅的原因。
> 因此"后端给设备发指令"只能通过 broker 中转，不能直连设备 IP。

结论：**模组、SIM、数据链路与接线全部可用**。剩下的是 GNSS 室外定位与 MQTT 联通。

## 1. 物料清单

| 部分 | 型号 | 关键点 |
|---|---|---|
| 主控 | **ESP32-S3** 开发板（实测 8 MB flash / 8 MB PSRAM） | 用 S3 的引脚规则，见 §3；**不是经典 ESP32** |
| 蜂窝 | Quectel **EC800M-CN**（实测 SKU：`EC800MCNGB`） | LTE Cat.1，GNSS 为选配，见 §2 |
| GNSS 天线 | 有源陶瓷天线 + IPEX | 与 4G 天线保持 ≥ 20 mm 间距 |
| 蜂窝天线 | LTE 全频段 FPC | 远离电池与金属车架 |
| 惯性 | MPU-6050（或 LIS3DH） | 震动/移动唤醒，低功耗模式下中断唤醒 ESP32 |
| NFC | **NTAG215**（504 B，可上锁） | 存 NDEF URI；写入后永久只读 |
| 电源 | 3.7 V 锂电（5000 mAh 级别）+ TP4056 类充电 | 需过放保护 |
| 稳压 | 3.3 V DC-DC（≥ 2 A 瞬时） | EC800M 发射瞬时电流可达 2 A 峰值 |
| 人机 | 1 个按键、1 个 RGB LED、1 个蜂鸣器 | 按键用于配网/重置本地状态与找车 |

## 2. ⚠️ EC800M 选型必读

EC800M-CN 的 **GNSS 是选配**，不同 SKU 硬件差异很大：

| 型号 | GNSS | 结论 |
|---|---|---|
| EC800MCN**GA** / EC800MCN**GD** / EC800MCN**GB** | 支持 GPS/BDS/GLONASS/Galileo | ✅ 可用（**GB 已实测：`AT+QGPS=1` 返回 OK**） |
| EC800MCN**LC** / EC800MCN**LE** | 不支持 | ❌ 买错就得外加 GNSS 模组 |

其他要点：

- GNSS 需要独立**有源天线**接口（`ANT_GNSS`）与备份电源脚（`GNSS_VBCKP`），否则热启动要几十秒。
  室内 `AT+QGPSLOC?` 返回 `CME ERROR: 516`（未定位）属于正常现象，需在室外或窗边等 30–90 秒。
- MQTT 用模组内置 AT 栈，ESP32 不需要跑 TCP/TLS：`AT+QMTOPEN` → `AT+QMTCONN` → `AT+QMTPUBEX` → `+QMTRECV` URC。
- 低功耗靠 **PSM / eDRX**，不是简单断电；断网重连的电流开销很大，尽量减少重连。
- 采购前确认 AT 手册版本（《ECx00x&EG800K&EG810M&EG91xN&EG915K&EG950A Series AT Commands Manual》），
  固件里引用的每条 AT 指令都要标注来源章节号。

## 3. 引脚分配（ESP32-S3）

S3 的引脚规则与经典 ESP32 差别很大，踩过的坑写在表后。

| 信号 | GPIO | 方向 | 说明 |
|---|---|---|---|
| `MODEM_TX` / `MODEM_RX` | **17 / 16** | out / in | UART1，115200 8N1，接 EC800M 主串口（**已实测跑通**） |
| `MODEM_PWRKEY` | 15 | out | 拉低 > 1 s 开机/关机；当前模组自启，低功耗阶段才需要 |
| `MODEM_RESET` | 7 | out | 低有效 |
| `MODEM_RI` | 8 | in | 模组有 URC/来电时唤醒 ESP32（下降沿） |
| `IMU_INT` | 4 | in | MPU-6050 运动中断，唤醒源 |
| `I2C_SDA` / `I2C_SCL` | 5 / 6 | io | MPU-6050 |
| `BUTTON` | 21 | in | 上拉，低有效；长按 10 s |
| `LED_RGB` | 42 | out | WS2812 或三路 PWM |
| `BUZZER` | 41 | out | LEDC 输出 |
| `BAT_ADC` | 1 | in | 分压后接 ADC1（**S3 的 ADC1 = GPIO1–10**） |
| `VBUS_DET` | 2 | in | 充电状态检测 |

### S3 引脚禁忌（照抄经典 ESP32 的表会在这里翻车）

- **GPIO19 / GPIO20 是原生 USB D-/D+**，接了 USB 就不能挪作它用。
- **GPIO26–32 固定接内部 flash**，不引出；**若模块带 Octal PSRAM（N8R8 常见），GPIO33–37 也不可用**。
  写代码时不要引用这些脚。
- **GPIO22 / 23 / 24 / 25 在 S3 上不存在**（经典 ESP32 有）。
- 启动 strapping 引脚：**GPIO0、3、45、46**，不要在上面挂上电即驱动的负载。
- `RX` / `TX` 两个丝印是 UART0（GPIO44/43），留给烧录与日志。
- ADC：S3 的 ADC1 在 GPIO1–GPIO10，ADC2 与 Wi-Fi 共用，电池电压请用 ADC1。
- 任意 GPIO 都能经 GPIO 矩阵映射到 UART，所以 UART 不必是"固定脚"。

## 4. 电源预算（估算，待实测）

| 状态 | 电流 | 占比假设 | 日均 |
|---|---|---|---|
| 深度睡眠（ESP32 + 模组 PSM） | ~50–150 µA | 22.5 h | ~3 mAh |
| 静止心跳（30 min 一次联网上报） | ~80 mA × 6 s | 48 次 | ~6 mAh |
| 骑行（10 s 采点 + 60 s 上报） | ~90 mA | 1 h | ~90 mAh |
| BLE 广播（仅未绑定/近场） | +2 mA | 少量 | ~1 mAh |

5000 mAh 电池在「每天骑 1 小时」下理论约 **40–50 天**；全程仅静态待机约 60 天以上。
**实测优先级高于上表**；M4 阶段用电流表跑 24 h 曲线校正。

降耗手段（按收益排序）：降心跳频率 → 骑行时不上报 alt/hdop → 用 PSM 而非断开重连 → 关闭 BLE 广播。

## 5. 天线与结构

- 4G 天线与 GNSS 天线**分置两端**，间距 ≥ 20 mm；不要平行走线。
- GNSS 天线朝上，避开金属车架遮挡；尽量放在车座下方或灯具壳内。
- BLE 与 4G 不必担心频段冲突（2.4 GHz vs LTE 频段），但 ESP32 天线要远离锂电池与金属。
- NFC 标签贴在**外壳外表面**、靠近车头，便于手机触碰；避开金属贴面（会屏蔽）。
- 整机需 IPX5 级别防水，按键与接口做密封。

## 6. deviceId 与产线流程

`deviceId` 格式：`BKL-<出厂年>-<6 位十进制序列>`，例 `BKL-2026-000123`。全生命周期唯一，不复用。

产线步骤：

1. 生成 `deviceId`、`claimCode`（16 字符 Base32）、`deviceSecret`（32 B base64）。
2. 用产线固件把 `deviceId` / `deviceSecret` 写入 NVS；`claimCode` **不写设备**。
3. 用 NFC 写卡器写 NDEF URI：`https://<domain>/bind?d=<deviceId>&c=<claimCode>`，随后**永久上锁**。
4. 上报后端：`deviceId` + `claimCode` 哈希 + `deviceSecret` 哈希 + `model` + 生产批次。
5. 烧录正式固件、跑自检（GNSS 首次定位、MQTT 连通、电量读数、按键/灯/蜂鸣）。
6. 丝印/贴纸标注 `deviceId`，与标签信息一致。

**风险点**：`claimCode` 明文只允许存在于产线工站内存与标签中；工站日志必须脱敏，任务结束即销毁。
标签一旦上锁无法改写，写错只能换标签——产线需先校验再锁。

## 7. 按键语义

| 操作 | 行为 |
|---|---|
| 短按（< 1 s） | 无（或触发一次电量显示） |
| 长按 3 s | 触发「找车」：灯闪 + 蜂鸣，便于确认设备在附近 |
| 长按 10 s | 重启并清除**本地** BLE 配对缓存；**不清服务端绑定**（见 [pairing.md §1](pairing.md)） |

注意：不做"长按恢复出厂"到可绑定状态——那等于给偷车者一个解绑按钮。
