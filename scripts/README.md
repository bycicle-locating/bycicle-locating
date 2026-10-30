# scripts

开发与硬件调试用的小工具。**都不是产品代码**，不上产线。

| 脚本 | 平台 | 用途 |
|---|---|---|
| `check-env.sh` | Git Bash / Linux | 检查 Go / Flutter / ESP-IDF / Docker 是否就绪 |
| `serial-diag.ps1` | Windows PowerShell | 读 ESP32 串口启动日志（拉 RTS 复位后抓 UART0） |
| `mpy-exec.ps1` | Windows PowerShell | 通过 MicroPython raw REPL 在板子上执行一段代码 |
| `at-probe.py` | 设备端（MicroPython） | 用 UART 给 EC800M 发 AT 指令，验证模组与接线 |
| `net-probe.py` | 设备端（MicroPython） | 验证 APN、PDP 激活与 DNS（MQTT 的前置条件） |
| `enable-branch-protection.sh` | Git Bash / Linux | 开启 GitHub 服务端分支保护（仓库为 public 后可用；升级 Team 后私有仓库也可用） |
| `board-probe.py` | 设备端（MicroPython） | 打印芯片型号、flash 大小、MAC、可用堆 |

## 典型流程（板子已刷 MicroPython 时）

```bash
# 1. 看板子活着没有、芯片是什么
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/serial-diag.ps1 -Port COM4

# 2. 确认 flash 容量与 MAC（写进 docs/hardware.md）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mpy-exec.ps1 `
    -CodeFile scripts/board-probe.py -Port COM4

# 3. 验证 4G 模组接线与 SIM 状态
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mpy-exec.ps1 `
    -CodeFile scripts/at-probe.py -Port COM4 -TimeoutMs 25000
```

## 两个容易踩的坑

1. **`.ps1` 必须是纯 ASCII**。Windows PowerShell 5.1 在没有 BOM 时按 ANSI 解析，
   中文会被打乱甚至导致引号不闭合、整个脚本语法错误。
2. **给板子发代码必须分块**。一次性 write 1 KB 以上会溢出 ESP32 的 UART 接收缓冲，
   板子收到的代码被截断，报 `SyntaxError`；`mpy-exec.ps1` 已按 96 字节分块发送。

## 注意

`at-probe.py` 里的 `TX_PIN` / `RX_PIN` 必须与实际接线一致（当前实测为 17/16）。
烧写 ESP-IDF 固件会覆盖板上的 MicroPython，这些脚本届时只能用于串口日志查看。
