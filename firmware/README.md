# firmware

ESP32 车载固件，ESP-IDF v5.x（C）。硬件见 [../docs/hardware.md](../docs/hardware.md)，
上行协议见 [../docs/protocol.md](../docs/protocol.md)。

> **验证状态**
> - 纯 C 模块（`app_types` / `proto_encode` / `ringbuf` / `uploader`）：✅ 已用 gcc 13
>   （`-std=c11 -Wall -Wextra -Werror`）编译并通过主机单测，见 `test/host/test_core.c`。
> - **硬件 bring-up（2026-10-30）**：✅ 模组 EC800MCNGB 已通过 UART1（GPIO17/16）验证——
>   `AT` / `ATI` / `AT+CPIN?` / `AT+CSQ` / `AT+CREG?` / `AT+CGREG?` 全部正常，`AT+QGPS=1` 返回 OK。
>   详见 `docs/hardware.md` §0。验证时板子跑的是 MicroPython，用的是 `scripts/at-probe.py`。
> - ESP-IDF 部分（`main.c`、`modem/`、`ble/`、`power/`）：⛔ **尚未编译验证**，
>   编写时机器上没有 ESP-IDF。首次 `idf.py build` 预计需修少量编译错误。

## 实现状态

| 模块 | 状态 | 说明 |
|---|---|---|
| `main/app_types` | ✅ 主机已验证 | 定点数据类型与校验 |
| `main/proto/proto_encode` | ✅ 主机已验证 | 纯整数 JSON 编码，不依赖 `%f` |
| `main/track/ringbuf` | ✅ 主机已验证 | 掉电安全环形缓冲，存储后端可替换 |
| `main/track/uploader` | ✅ 主机已验证 | 批量/退避/成功后 commit |
| `main/modem/modem_at` | ⛔ 桩 | AT 引擎（M1） |
| `main/modem/modem_mqtt` | ⛔ 桩 | QMTOPEN/CONN/PUBEX（M1） |
| `main/modem/modem_gnss` | ⛔ 桩 | QGPS 采样（M1） |
| `main/ble/ble_status` | ⛔ 桩 | GATT 状态服务（M1） |
| `main/power/power_mgr` | ⛔ 桩 | 睡眠与唤醒（M4） |

标 ✅ 的模块不依赖任何 ESP-IDF 头文件，可以脱离硬件直接跑主机单测。

## 命令

```bash
# 主机单测：不需要 ESP-IDF，普通 gcc 即可（CI 会跑这一步）
cd firmware
gcc -std=c11 -Wall -Wextra -Werror \
    -I main -I main/proto -I main/track \
    test/host/test_core.c main/app_types.c main/proto/proto_encode.c \
    main/track/ringbuf.c main/track/uploader.c -o test_core
./test_core        # 输出「全部主机单测通过」

# 固件构建：一次性环境，安装 ESP-IDF v5.x 并
. $IDF_PATH/export.sh

idf.py set-target esp32s3
idf.py menuconfig        # 确认 partitions.csv、flash 大小、设备型号
idf.py build
idf.py -p <PORT> flash monitor

# 打开开机自检（合成数据跑一遍 ringbuf→encode→publish，只打日志）
idf.py menuconfig        # 自行车定位设备 → 开机自检
```

## 分区

`partitions.csv` 按**实测 8 MB flash** 布局：双 OTA 槽各 3 MB + 1.875 MB 的 `track` 数据分区。
`track` 分区用来放 LittleFS 上的环形缓冲文件，**不要**把它当普通文件系统随意写，
所有写入必须经过 `ringbuf`。

> 换板子（4 MB flash）时要同步改 `partitions.csv` 的 OTA 槽大小与
> `sdkconfig.defaults` 的 `CONFIG_ESPTOOLPY_FLASHSIZE_*`，否则会烧写失败或分区越界。

## 硬规则

1. **AT 指令字符串只允许出现在 `main/modem/`。** 其他模块调用 `modem_*` 接口。
2. **采样任务不得阻塞在网络或 AT 上。** GNSS 采样 → 写缓冲 → 返回；上报由独立任务驱动。
3. **先持久化 `seq`，再使用它。** `seq` 是跨报文全局唯一的幂等键（protocol.md §3.1）。
4. **发布成功才 commit 缓冲。** 宁可在网络恢复后重传，也不能删掉没发出去的点。
5. **`seq`/缓冲元数据必须跨深度睡眠保留**（NVS 或 RTC 内存），否则重启后幂等失效。
6. **睡眠前主动发布 `online:false`**：主动断开不会触发 broker 的遗嘱消息（protocol.md §2.2）。
7. **BLE 不实现绑定。** 绑定只走 NFC + 后端校验（pairing.md）。

## 已知坑

- `CONFIG_NEWLIB_NANO_FORMAT=y` 时 `printf` 不支持 `%f` —— 所以全部用整数定点格式化。
- EC800M 的 GNSS 是选配，`AT+QGPS=1` 在无 GNSS 的 SKU 上会直接报错；型号不对换不了固件解决。
- URC（`+QMTRECV` / `+QMTSTAT` / `RDY`）会插在指令回显中间，必须按行解析。
- `AT+QMTPUBEX` 是"等 `>` 再发裸数据"的两段式，别用一次 `bkl_at_cmd` 搞定。
- 深度睡眠会清 RAM，`s_ring` 这类静态结构唤醒后必须重建并从 NVS 恢复。
- BLE 单次写入只有 20 字节，MTU 协商在 Android/iOS 上行为不同（pairing.md §5.3）。

## 目录

```
main/
  main.c             app_main：初始化、自检、任务装配
  app_types.h/.c     定点数据类型与校验
  Kconfig.projbuild  型号、间隔、自检开关
  proto/             线格式编码（与后端 internal/protocol 对偶）
  track/             离线缓冲与上报状态机
  modem/             EC800M：AT 引擎、MQTT、GNSS
  ble/               近场状态服务（无绑定能力）
  power/             睡眠策略
```

## M1 待办

- [ ] `ringbuf` 换成 track 分区上的 LittleFS 后端，并把元数据写入 NVS
- [ ] `modem_at` 的 UART + 行解析 + 超时
- [ ] `modem_mqtt` 的 QMTOPEN/CONN/PUBEX 与断线重连
- [ ] `modem_gnss` 的 QGPSLOC 解析（注意 km/h → m/s）
- [ ] 采集任务与上报任务分离，用事件组驱动
- [ ] 扩充主机单测：满盘、掉电恢复、时区边界（`epoch_to_civil`）
