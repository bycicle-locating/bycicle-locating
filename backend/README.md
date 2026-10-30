# backend

设备接入与 App 数据服务。技术栈 Go 1.22，**骨架阶段只用标准库**，因此不联网也能 `go build`。

> ✅ 已在 Docker（`golang:1.22`）中验证：`go build` / `go vet` / `go test` / `gofmt -l` 全部通过，
> 绑定接口的 200 / 409 / 403 / 401 四条路径也已冒烟验证。没装 Go 时可这样复现：
>
> ```bash
> docker run --rm -v "$PWD":/src -w /src golang:1.22 sh -c 'gofmt -l . && go vet ./... && go test ./...'
> ```

## 当前实现状态

| 部分 | 状态 |
|---|---|
| `internal/protocol` | ✅ 已完成（信封解析与校验、主题解析、指令编码） |
| `internal/store` | ⚠️ 只有内存实现；Postgres 属 M1 |
| `internal/ingest` | ✅ 骨架完成（去重、事件、状态），指令确认待 M1 |
| `internal/device` | ✅ 绑定/解绑 + 声明码 HMAC 校验，限流待 M1 |
| `internal/api` | ⚠️ 有 `/healthz`、绑定、解绑、查设备；**鉴权是开发桩** |
| `internal/mqtt` | ⚠️ 只有 `LogBus`，不会真收发；paho 实现属 M1 |

## 命令

```bash
go build ./...
go vet ./...
go test ./... -v
gofmt -w .            # CI 会校验 gofmt -l 为空

# 本地跑起来（无需数据库与 broker）
APP_ENV=dev DEV_SEED_CLAIM=7QK2M5XJ4TZP6RWN go run ./cmd/server

# 冒烟：绑定演示设备
curl -s -X POST localhost:8080/v1/devices:bind \
  -H 'Content-Type: application/json' \
  -H 'X-Dev-User: 11111111-1111-1111-1111-111111111111' \
  -d '{"deviceId":"BKL-2026-000001","claimCode":"7QK2M5XJ4TZP6RWN","label":"通勤车"}'

# 本地依赖（broker + postgres）
docker compose up -d
```

## 结构

```
cmd/server/main.go        进程装配：HTTP + MQTT 消费 + 优雅退出
internal/protocol/        线格式（唯一解析 JSON 的地方）
internal/store/           Store 接口 + 内存实现
internal/ingest/          报文落库服务（纯逻辑，可单测）
internal/device/          绑定领域服务 + 声明码哈希
internal/mqtt/            Bus 接口 + 日志实现
internal/api/             HTTP handler 与中间件
internal/config/          环境变量
```

## 几条硬规则

1. **SQL 只能出现在 `store` 的实现里**，接口不暴露 `pgx`/`sql.Row` 类型。
2. **handler 不写业务判断**：鉴权、解码、调用 service、编码，仅此而已。
3. **幂等靠主键**：`(device_id, seq)` 唯一；应用层不做"先查再插"。
4. **绑定必须原子**：校验声明码 + 占用该码 + 写车主在同一条 SQL 里完成（见 `docs/data-model.md` §3）。
5. **不要在生产启用开发鉴权**：`APP_ENV=prod` 时 `main.go` 会直接拒绝启动，直到 JWT 落地。

## 待办（M1）

- [ ] paho MQTT 客户端实现 `mqtt.Bus`，接 `wireIngest`
- [ ] Postgres 实现 `store.Store` + 迁移脚本
- [ ] JWT 鉴权 + 用户表
- [ ] `cmd_ack` 更新 `commands` 状态
- [ ] 绑定限流（同账号 10 次/小时）
