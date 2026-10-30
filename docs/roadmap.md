# 路线图

当前处于 **M0（骨架）**。每个里程碑都有可验证的退出标准，不以「代码写完」为准。

## M0 — 仓库骨架（本次）

- [x] 目录结构、协议与架构文档、ADR
- [x] 三层空实现与接口定义
- [x] 协作规范与 AI 工作约束（AGENTS.md）
- [x] 环境自检脚本 `scripts/check-env.sh`
- [x] `backend/` 构建通过：`go build` / `go vet` / `go test` / `gofmt`（Docker `golang:1.22`）
- [x] `backend/` 绑定接口冒烟：200 绑定成功 / 409 已绑定 / 403 声明码错误 / 401 未登录
- [x] `app/` 通过 `flutter analyze`（0 issue）、`flutter test`、`dart format`（Flutter 3.44）
- [x] `firmware/` 纯 C 模块通过 gcc 13 编译与主机单测
- [ ] `app/` 生成 `android/`、`ios/` 平台工程并可打包（需先定 applicationId）
- [ ] `firmware/` 通过 `idf.py build`（待安装 ESP-IDF）

**退出标准**：三层各跑通一次构建。后端与 app 静态检查已达成；固件仅纯 C 模块已达成，ESP-IDF 构建待工具链。

## M1 — 链路打通

目标：从设备到 App 的一条最小链路。

- [x] 硬件 bring-up（2026-10-30）：ESP32-S3 + EC800MCNGB，`AT`/`ATI`/`AT+CPIN?`/`AT+CSQ`/`AT+CREG?`/`AT+CGREG?`
      全部正常，`AT+QGPS=1` 返回 OK，UART 为 GPIO17(TX)/GPIO16(RX)
- [x] 数据链路：APN `CMNET`、`AT+CGATT?`=1、`AT+QIACT=1` 拿到 IP、DNS 可解析（运营商 CGNAT）
- [ ] GNSS 室外首次定位（`AT+QGPSLOC?` 返回有效坐标与时间）
- [ ] 模组侧 MQTT 连通：`AT+QMTOPEN` → `AT+QMTCONN` → `AT+QMTPUB`
- [ ] ST25DV16K 接入：I²C 识别（读 UID）、NDEF 读写与读回校验、天线调谐后实测读距
- [ ] 锁屏触碰实测：Android 与 iOS（Type 5 的后台读取得真机确认）
- [ ] 后端：MQTT 订阅 + `internal/protocol` 校验 + `Store` Postgres 实现 + 迁移脚本
- [ ] 固件：`modem_at` 真实实现（UART + URC），`modem_mqtt` 完成 QMTOPEN/CONN/PUBEX
- [ ] 固件：`track/ringbuf` 落 LittleFS，`uploader` 批量与退避
- [ ] App：`ApiClient` 接后端，地图页显示"最后已知位置"
- [ ] App：NFC 读取 → 绑定 → 状态刷新
- [ ] Mosquitto TLS + 每设备账号 ACL 跑通

**退出标准**：实机开机后 5 分钟内，App 上出现至少一个真实轨迹点；主动拔掉天线后数据不丢，复网后补传成功。

## M2 — 骑行记录

- [ ] 后端：`internal/ride` 骑行切分与统计（距离剔跳变、静止判定）
- [ ] 后端：`GET /v1/rides`、`/v1/rides/{id}`、轨迹抽稀
- [ ] App：骑行列表、详情、地图轨迹回放、速度/里程摘要
- [ ] 单位换算全部在展示层（m/s → km/h），存储与传输保持 SI

**退出标准**：一次 10 km 骑行，App 显示的里程与手机 GPS 记录误差 < 3%。

## M3 — 防盗

- [ ] 后端：围栏 CRUD + 进出判定 + 告警去重（同设备 10 分钟内同类只报一次）
- [ ] 后端：`alerts` + WebSocket 推送；`context` 快照便于复盘误报
- [ ] 固件：震动中断 → `event{motion}` + 临时提高采样率
- [ ] 后端：解绑接口（仅车主）+ 审计
- [ ] 声明码轮换（`cmd: write_claim`）：设备改写标签 NDEF，旧码失效，关闭"解绑 → 重绑"克隆窗口
- [ ] App：告警页、已读、围栏编辑；「车在附近」仅作提示

**退出标准**：锁车后轻推触发告警，推送延迟 < 15 s；连续 7 天无误报（或误报率可量化）。

## M4 — 低功耗与量产

- [ ] 24 h 电流曲线实测，校正 `hardware.md` §4
- [ ] 深度睡眠策略（PSM/eDRX + 睡眠前发 `online:false`）
- [ ] OTA（双分区 + 回滚 + 版本灰度）
- [ ] 产线工具：NVS 写入 + NFC 标签写入（ST25DV，不加只读锁）+ 自检
- [ ] CI：app 与 firmware 的构建流水线（当前仅有 backend）

**退出标准**：满电待机 ≥ 30 天（每天 1 h 骑行）；OTA 失败可自动回滚。

## 暂不做（记录在案，避免反复讨论）

- iOS/Android 之外的平台（Web 端只做落地页）
- 设备端本地轨迹压缩与围栏判定
- 多用户共享同一辆车（先按单车主设计）
- 社交/排行/路线推荐
