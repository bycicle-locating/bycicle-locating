# 变更说明

<!-- 一句话说清这个 PR 解决了什么问题。如果它关联 issue，写 Closes #123。 -->

## 为什么

<!--
写动机，不写实现。评审的人需要能判断"该不该改"，
而不只是"这段代码写得对不对"。
-->

## 改了什么

- 

## 影响面

- [ ] 涉及协议字段 / 主题 / 单位 → 已同步 `docs/protocol.md` 或 `docs/pairing.md`，并说明是否兼容
- [ ] 涉及数据库结构 → 已同步 `docs/data-model.md`，并给出迁移方式
- [ ] 涉及引脚 / 功耗 / 硬件 → 已同步 `docs/hardware.md`
- [ ] 新增依赖 → 已说明理由与体积影响（固件尤其注意 flash/RAM）
- [ ] 新增配置项 → 已进 `.env.example` 或 `sdkconfig.defaults`，且有默认值

## 自检

- [ ] `backend/`：`go build ./... && go vet ./... && go test ./...`（或看 CI）
- [ ] `app/`：`flutter analyze` 0 issue、`dart format --set-exit-if-changed .`、`flutter test`
- [ ] `firmware/`：纯 C 主机单测通过；改动 ESP-IDF 部分时 `idf.py build`
- [ ] 没有残留调试代码（`print` / `fmt.Println` / 注释掉的大段代码）
- [ ] 日志与错误信息里没有密钥、token、声明码、完整坐标

## 安全相关（命中任一必须说明）

- [ ] 本 PR 触碰了绑定/解绑逻辑
- [ ] 本 PR 触碰了 BLE 或 RSSI 相关判定
- [ ] 本 PR 触碰了报文校验或主题白名单

<!--
如果命中，请在下面写明：改动后攻击者还能做什么、不能做什么。
三条红线见 AGENTS.md §3.5。
-->
