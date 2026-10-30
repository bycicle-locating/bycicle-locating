# 设备 ↔ 云协议 v1

本文件是**固件与后端的唯一契约**。改字段前先改这里（见 [CONTRIBUTING.md](../CONTRIBUTING.md) §2）。

## 1. 传输

| 项 | 取值 | 理由 |
|---|---|---|
| Broker | Mosquitto（自建，`docker-compose.yml`） | 单机够用，运维简单 |
| 端口 | 8883（MQTT over TLS） | 明文 1883 仅限本地开发 |
| 客户端 | EC800M 内置 MQTT AT 栈 | 不需在 ESP32 上实现 TCP/TLS |
| Keepalive | 120 s | Cat.1 省电与掉线检测的折中 |
| Clean Session | `1`（true） | 设备自带离线缓冲，不依赖 broker 排队 |
| Payload 上限 | 4096 字节 | 受模组 AT 发送缓冲与 RAM 限制 |
| 编码 | UTF-8 JSON | 便于抓包与联调 |

所有时间戳为 **UTC，RFC3339**（`2026-10-30T06:12:03Z`）。设备不得上报本地时区。

> **连接方向是单向的**：实测模块在运营商 CGNAT 之后（会话 IP 形如 `10.43.x.x`），
> 后端**永远无法主动连接设备**。因此 broker 必须公网可达，且所有下行都只能走
> "设备订阅 + broker 转发"。任何需要后端直连设备 IP 的方案都不可行。

## 2. 主题

`{id}` 为 `deviceId`（格式见 [hardware.md](hardware.md) §1）。

| 主题 | 方向 | QoS | Retained | 用途 |
|---|---|---|---|---|
| `v1/device/{id}/telemetry` | 上行 | 1 | 否 | 轨迹点批量上报 |
| `v1/device/{id}/event` | 上行 | 1 | 否 | 告警与状态变更 |
| `v1/device/{id}/status` | 上行 | 1 | **是** | 在线状态，后端据此判活 |
| `v1/device/{id}/cmd` | 下行 | 1 | 否 | 云端指令 |
| `v1/device/{id}/cmd/ack` | 上行 | 1 | 否 | 指令确认 |

设备订阅 `v1/device/{id}/cmd`，其余为自己发布。后端只订阅 `v1/device/+/+` 与 `v1/device/+/cmd/ack`，遇未知设备直接丢弃并记一次审计日志。

### 2.1 遗嘱消息（LWT）

设备 CONNECT 时注册：

- 主题：`v1/device/{id}/status`
- QoS 1，retained
- 载荷：`{"v":1,"id":"<deviceId>","online":false,"ts":"<连接时刻>"}`

### 2.2 ⚠️ 正常断连必须自己发离线状态

broker **只在非正常断开时**发布 LWT。设备主动 `DISCONNECT`（如进入深度睡眠）前必须自己发布一条
`{"online":false,...}` 到 `status`，否则后端会一直认为设备在线。这是最容易踩的坑，固件 `uploader` 负责保证。

## 3. 信封

所有上行报文共享同一信封：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `v` | int | 是 | 协议主版本，当前 `1` |
| `id` | string | 是 | `deviceId` |
| `seq` | uint32 | 是 | 设备单调递增计数器，**持久化到 flash**，重启不重置。见 §3.1 |
| `ts` | string | 是 | 本条报文生成时间（UTC） |
| `type` | string | 是 | `telemetry` / `event` / `status` / `cmd_ack` |
| `fw` | string | 否 | 固件版本，便于灰度排查 |
| `battery` | object | 否 | `{"mv":3890,"pct":76}`（`pct` 可缺省） |
| `net` | object | 否 | `{"rsrp":-92,"rssi":15}`（EC800M `AT+QENG` / `AT+CSQ`） |

**幂等**：后端以 `(id, seq)` 为唯一键。重复到达视为成功并回 `ack`，不重复落库。
**排序**：只信 `seq`，不信 `ts`——设备时钟在无 GNSS 时不可靠。

### 3.1 seq 的分配规则（重要）

设备只有一个单调计数器，**每个轨迹点、每条 event/status/cmd_ack 各占一个号**：

- 采样一次 → 取一个新 `seq`，写入该轨迹点，并在 flash 里持久化计数器。
- `telemetry` 信封的 `seq` 取**本批最后一个点的 `seq`**，仅用于日志与人工排查；
  真正的主键是**每个点自己的 `seq`**。
- 这样 `(id, seq)` 在所有报文类型之间全局唯一，`telemetry_points` 才能用
  `PRIMARY KEY (device_id, seq)` 做去重，批量重传也不会冲突。

## 4. telemetry

```json
{
  "v": 1, "id": "BKL-2026-000123", "seq": 1042,
  "ts": "2026-10-30T06:12:03Z", "type": "telemetry", "fw": "0.1.0",
  "battery": { "mv": 3890, "pct": 76 },
  "points": [
    { "seq": 1042, "t": "2026-10-30T06:11:58Z", "lat": 31.2304, "lon": 121.4737,
      "spd": 6.2, "crs": 187.5, "alt": 12.4, "hdop": 0.9, "fix": 3, "acc": 4.0 },
    { "seq": 1043, "t": "2026-10-30T06:12:08Z", "lat": 31.2307, "lon": 121.4741,
      "spd": 6.8, "crs": 185.0, "fix": 3 }
  ],
  "dropped": 0
}
```

| 字段 | 单位 | 说明 |
|---|---|---|
| `seq` | — | 该点独占的序号，见 §3.1，必须 > 0 |
| `lat` / `lon` | 度 | WGS-84。**不要**上报 GCJ-02，转换在 App 显示层做 |
| `spd` | **m/s** | 线速度；App 负责换算 km/h |
| `crs` | 度 | 航向 0–360，0 = 正北 |
| `alt` | 米 | 可缺省 |
| `hdop` | — | 水平精度因子；> 3 的点后端标记为低质量 |
| `fix` | 枚举 | `0` 无定位 / `2` 2D / `3` 3D |
| `acc` | 米 | 估算水平误差，可缺省 |
| `dropped` | 个 | 本轮因缓冲满丢弃的旧点数，供监控缓冲健康度 |

批量约束：单条 ≤ 60 点、≤ 4096 字节。点按 `t` 升序。

## 5. event

```json
{
  "v": 1, "id": "BKL-2026-000123", "seq": 1043,
  "ts": "2026-10-30T06:20:00Z", "type": "event",
  "event": "motion", "level": "critical",
  "lat": 31.2304, "lon": 121.4737,
  "data": { "dur_s": 4, "peak": 2.1 }
}
```

`event` 取值：`motion`（震动/移动）、`geofence_exit`、`geofence_enter`、`tamper`（开壳）、
`low_battery`、`power_on`、`power_off`、`gnss_lost`。
`level`：`info` / `warn` / `critical`。

事件报文**不参与批量**，独立发布、优先于轨迹点，且不得因网络失败而丢弃——失败则进入高优先级重传队列。

## 6. status

```json
{ "v": 1, "id": "BKL-2026-000123", "seq": 1044, "ts": "...", "type": "status",
  "online": true, "fw": "0.1.0", "gpsFix": true, "ble": false,
  "battery": { "mv": 3890, "pct": 76 }, "net": { "rsrp": -92 } }
```

retained，上线后立即发布一次，之后每 5 分钟刷新。

## 7. cmd（下行）

```json
{ "v": 1, "cmdId": "0b6f5f4e-...", "cmd": "locate", "params": {}, "issuedAt": "..." }
```

| `cmd` | `params` | 设备行为 |
|---|---|---|
| `locate` | `{"timeout_s":60}` | 立即开 GNSS、连网、上报一次 `telemetry` |
| `bind` | `{"userId":"...","label":"..."}` | 写入绑定状态，转 `CLAIMED`，关闭 BLE 广播 |
| `unbind` | `{}` | 清除绑定与凭据，转 `CLAIMABLE` |
| `set_config` | 见 §7.1 | 更新采样/上报/灵敏度 |
| `write_claim` | `{"claimCode":"<16 位 Base32>"}` | **M3**：把新声明码写入 ST25DV16K 的 NDEF 并读回校验，见 §7.3 |
| `reboot` | `{"delay_s":5}` | 重启 |

### 7.1 set_config 允许的键

| 键 | 单位 | 范围 | 含义 |
|---|---|---|---|
| `sample_interval_s` | 秒 | 5–600 | 骑行时采样间隔 |
| `upload_interval_s` | 秒 | 30–3600 | 批量上报间隔 |
| `idle_interval_s` | 秒 | 60–3600 | 静止时心跳/定位间隔 |
| `motion_sensitivity` | 1–10 | 1 最钝 | 震动触发阈值 |
| `ble_enabled` | bool | — | 是否允许近场连接 |

未知键必须**忽略**而不是报错，便于云端先上配置、固件后升级。

### 7.2 ack

```json
{ "v": 1, "id": "...", "seq": 1045, "type": "cmd_ack",
  "cmdId": "0b6f5f4e-...", "ok": false, "error": "unknown_cmd", "result": {} }
```

`error` 取值：`unknown_cmd` / `bad_params` / `busy` / `not_supported` / `internal`。
设备必须在 30 s 内 ack；超时后云端标记 `timeout` 并可选重试一次（同 `cmdId`）。

### 7.3 write_claim：声明码轮换（M3）

标签是 ST25DV16K，设备能经 I²C 改写它，因此可以让旧声明码彻底失效，
从而关闭"解绑 → 重绑"期间的克隆窗口（[ADR-0004](adr/0004-st25dv16k-tag.md)）。

**必须由后端生成新码**：后端只存带 pepper 的 HMAC，设备算不出同一个哈希，
所以不能让设备自己生成再上报，只能由后端下发。

**触发与授权**：轮换等同于更换绑定凭证，与 `unbind` 同级敏感，**只能由当前车主账号发起**。
轮换成功后 App 必须丢弃本地缓存的旧码，否则用户拿旧码去绑会得到 403。

两阶段，顺序不能颠倒：

1. 后端生成新码 `C1`，**先不切换**生效哈希，下发 `write_claim{claimCode:C1}`；
2. 设备写 NDEF、读回校验，`cmd/ack` 返回 `ok`；
3. 后端收到 `ok` 后才把生效哈希切到 `C1`，旧码立即失效。

失败处理：

| 情况 | 处理 |
|---|---|
| 设备回 `ok:false` | 后端保持旧哈希，标签仍是旧码，可重试 |
| 设备在线但 ack 丢失 | 标签可能已是新码而后端仍是旧码 → 后端保留**旧哈希宽限期**（建议 24 h），期间两者都能校验 |
| 设备长期离线 | 不下发；等服务端重连后由 `status` 或下一次连接触发 |

设备侧约束：

- 写入前必须确认当前**没有 RF 场**（手机正在读时写会失败或写坏），用 ST25DV 的 GPO 判断；
- 写入后**读回校验**，不一致则回 `ok:false`，绝不回 `ok:true` 蒙混；
- 标签里除 NDEF URI 之外不要存放任何密钥。

## 8. 离线缓冲

固件侧用 flash FIFO（`main/track/ringbuf.c`）：

- 容量目标 ≥ 72 小时轨迹（按 10 s 采样估算）。
- FIFO 满时**丢最旧**并累加 `dropped`，绝不丢新点——旧点价值低于新点。
- 用时间窗口做二次保护：超过 7 天的点在上报前丢弃。
- 上报成功指收到 broker PUBACK，**不是**云端 ack；云端确认靠 `(id,seq)` 幂等。

## 9. 版本演进

- 新增**可选**字段：不改 `v`，旧端忽略即可。
- 字段含义/单位变化、必填变多、删除字段：提升 `v`，新增 `v2/` 主题前缀，双跑一个版本周期。
- 设备在 `status` 里上报 `fw`，后端据此做兼容性判断与灰度。

## 10. 认证

- 每设备独立 MQTT 用户名 = `deviceId`，密码 = 出厂写入 NVS 的 `deviceSecret`（32 字节随机，base64）。
- Broker 用 `mosquitto_passwd` 生成的文件做认证；TLS 用服务端证书，设备侧校验 CA 指纹。
- ACL：设备只能读写自己的 `v1/device/{id}/#` 与订阅自己的 `cmd`。
- 后端用独立的服务端账号订阅 `v1/device/+/+`。
- 丢弃策略：载荷 > 4 KB、未知 `id`、未知 `v`、`seq` 回退超过 1000 的报文直接丢弃并计数。
