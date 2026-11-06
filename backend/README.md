# backend

设备接入与 App 数据服务。技术栈 Go 1.27；Postgres 用 `pgx`，密码哈希用
`golang.org/x/crypto/argon2`，JWT 用标准库 HS256。首次构建需要下载模块。

> ✅ 已验证（2026-11-06）：
> - `go build` / `go vet` / `go test` / `gofmt -l` 通过；
> - 内存栈 Docker Compose e2e、Postgres 栈（迁移 + JWT + 用户/设备）e2e 通过；
> - 未装 Go 时可这样复现静态检查：
>
> ```bash
> docker run --rm -v "$PWD":/src -w /src -e GOPROXY=https://goproxy.cn,direct \
>   golang:1.27 sh -c 'gofmt -l . && go vet ./... && go test ./...'
> ```

## 当前实现状态

| 部分 | 状态 |
|---|---|
| `internal/protocol` | ✅ 已完成（信封解析与校验、主题解析、指令编码） |
| `internal/store` | ✅ Memory + Postgres 实现 + `internal/store/migrations` |
| `internal/ingest` | ✅ 骨架完成（去重、事件、状态），指令确认待 M1 |
| `internal/device` | ✅ 绑定/解绑 + 声明码 HMAC 校验，限流待 M1 |
| `internal/auth` | ✅ HS256 JWT 签发/校验 |
| `internal/user` | ✅ 注册/登录/资料/我的设备；argon2id 密码哈希 |
| `internal/api` | ✅ `/healthz`、用户、JWT、绑定/解绑/查设备 |
| `internal/mqtt` | ⚠️ 只有 `LogBus`，不会真收发；paho 实现属 M1 |

## 部署（Docker Compose）

拓扑：公网 `https://bycicle-locating.top` → **Cloudflare Tunnel** → **nginx**（唯一入口，
非 root、只读根文件系统）→ **backend:8080**（只在内网）。backend 与 nginx 都不发布公网端口；
直连端口默认只绑 `127.0.0.1`。

当前联调实例（域名、Tunnel、Access、测试方式）见 [`docs/deployment.md`](../docs/deployment.md)。
HTTP API（注册/登录/用户/设备）契约见 [`docs/http-api.md`](../docs/http-api.md)。
公网实例已启用 Cloudflare Access（`bicycle-locating-api`）；未带登录态或服务令牌的请求会
302 到团队登录页。`smoke.sh` 检测到 `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`
时会自动加 Access 头。

```bash
cp .env.example .env      # 填 CLAIM_PEPPER、JWT_SECRET；接 Postgres 再填 DATABASE_URL
docker compose up -d --build --wait        # dev 内存模式，重启丢数据
docker compose ps
curl -s "localhost:${BKL_HTTP_PORT:-32525}/healthz"

# Postgres 持久化：先起库，再执行一次性迁移，最后起应用
docker compose --profile deps up -d --wait postgres
docker compose --profile deps run --rm migrate
docker compose --profile deps up -d --build --wait backend nginx

# 更新代码后重建容器；不加 --force-recreate 时 compose 可能继续跑旧镜像
docker compose up -d --build --force-recreate --wait
```

- 对外端口由 `BKL_HTTP_PORT` 控制，默认 **32525**；`BKL_BIND_ADDR` 默认 `127.0.0.1`，直连需显式放开。
- `.env` 只由 Compose 读取；服务本身只认进程环境变量。
- `CLAIM_PEPPER` 必填且至少 16 字节；`JWT_SECRET` 至少 32 字节；`POSTGRES_PASSWORD` 在启动 postgres 时必须设置。
- `DATABASE_URL` 为空且 `APP_ENV=dev` 时回退内存；`APP_ENV=prod` 必须设置 `DATABASE_URL` 和 `JWT_SECRET`。
  容器内主机名是 `postgres`，密码含特殊字符时需要 URL-encode。
- `deploy/migrate` 是一次性 `psql` 任务，SQL 在 `internal/store/migrations/`；应用启动只做 schema 检查，不会自动建表。
- TLS 由 Cloudflare Tunnel 终止；nginx 只在内网监听 HTTP。
- 若服务器在中国大陆云厂商，域名需完成 ICP 备案；未备案时云厂商边缘会按 Host 拦截
  （阿里云返回 `Server: Beaver` 的 403），换非标端口也不能绕过，与 nginx / 后端无关。
  当前通过 Cloudflare Tunnel 主动出站绕开该入站拦截。
- Postgres 模式下绑定/用户/轨迹持久化在 `pg-data` 卷；内存模式 `docker compose restart backend` 会丢数据。

### 全链路测试

```bash
# 从零拉起隔离栈（独立 project、端口 18080），跑完自动销毁
bash deploy/e2e.sh

# 对运行中的实例冒烟（BASE_URL 指向 nginx；DEV_USER_ID 显式传入，公网实例不回退）
set -a; . ./.env; set +a
BASE_URL="http://127.0.0.1:${BKL_HTTP_PORT:-32525}" \
  DEV_USER_ID=11111111-1111-1111-1111-111111111111 \
  CLAIM_CODE="$DEV_SEED_CLAIM" bash deploy/smoke.sh

# 公网实例冒烟：在开发机（客户端）上执行；服务令牌从服务器 .env / Zero Trust 面板取
BASE_URL="https://bycicle-locating.top" \
  DEV_USER_ID=11111111-1111-1111-1111-111111111111 \
  CLAIM_CODE="$DEV_SEED_CLAIM" \
  CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... \
  bash backend/deploy/smoke.sh

# 用户 API：注册/登录/资料/我的设备；同样支持 CF_ACCESS_* 头
BASE_URL="http://127.0.0.1:${BKL_HTTP_PORT:-32525}" \
  CLAIM_CODE="$DEV_SEED_CLAIM" \
  bash deploy/user-smoke.sh

# Postgres 临时栈：postgres → migrate → backend → nginx → 用户/设备冒烟
bash deploy/e2e-postgres.sh
```

不要从服务器本机跑域名 smoke：服务器出站到 Cloudflare 的回程偶发丢响应，会误报超时；
服务器本机请用 `http://127.0.0.1:32525` 直连 nginx。

e2e 覆盖 healthz、绑定 200、重复绑定 409、错误声明码 403、非车主读写 403、解绑 204、
解绑后不可见、用户注册/登录/资料/我的设备，以及 backend 重建后 nginx 自动恢复。
`e2e-postgres.sh` 会额外验证迁移、Postgres Store 与 JWT-only 模式；它不纳入必需 CI 检查。

### 依赖服务

`postgres` / `migrate` 在 `deps` profile 下；`broker` 也在同一 profile，但开发 broker
是匿名配置，生产不要把它一起启动。只起数据库和迁移：

```bash
docker compose --profile deps up -d --wait postgres
docker compose --profile deps run --rm migrate
```

### Cloudflare Tunnel（可选）

源站在中国大陆且域名未备案时，80/8080 等端口的入站请求会被云厂商按 Host 拦截，
普通 Cloudflare 代理也无法绕过（回源仍收到 403）。Tunnel 由服务器**主动出站**连接
Cloudflare，可绕开入站拦截，并自动提供 443 证书。

1. Cloudflare Zero Trust → Networks → Tunnels → 创建隧道，复制 token。
2. 在 `.env` 设置 `TUNNEL_TOKEN`。
3. 启动：`docker compose --profile tunnel up -d cloudflared`
4. 隧道 Public Hostname 配为 `bycicle-locating.top` → `http://nginx:8080`。

该主机名若已有 A/AAAA 记录，需先删除（或让隧道的 CNAME 替换它），否则 Cloudflare
无法自动创建 DNS 记录。默认部署不启动该服务；`TUNNEL_TOKEN` 为空也不影响 `docker compose up`。

## 本地构建与测试

```bash
go build ./...
go vet ./...
go test ./... -v
gofmt -w .            # CI 会校验 gofmt -l 为空

# 直接跑二进制（不经过容器）
set -a; . ./.env; set +a
go run ./cmd/server
```

## 结构

```
cmd/server/main.go        进程装配：HTTP + MQTT 消费 + 优雅退出
internal/protocol/        线格式（唯一解析 JSON 的地方）
internal/store/           Store 接口 + Memory + Postgres + migrations
internal/ingest/          报文落库服务（纯逻辑，可单测）
internal/device/          绑定领域服务 + 声明码哈希
internal/auth/            HS256 JWT 签发/校验
internal/user/            注册、登录、资料、argon2id
internal/mqtt/            Bus 接口 + 日志实现
internal/api/             HTTP handler 与中间件
internal/config/          环境变量
Dockerfile                多阶段构建 → 非 root 静态镜像
docker-compose.yml        nginx + backend（postgres/migrate 在 deps profile）
deploy/nginx/             反向代理配置
deploy/smoke.sh           设备绑定冒烟
deploy/user-smoke.sh      用户 API 冒烟
deploy/e2e.sh             内存栈全链路测试
deploy/e2e-postgres.sh    Postgres 栈全链路测试
```

## 几条硬规则

1. **SQL 只能出现在 `store` 的实现里**，接口不暴露 `pgx`/`sql.Row` 类型。
2. **handler 不写业务判断**：鉴权、解码、调用 service、编码，仅此而已。
3. **幂等靠主键**：`(device_id, seq)` 唯一；应用层不做"先查再插"。
4. **绑定必须原子**：校验声明码 + 占用该码 + 写车主在同一条 SQL 里完成（见 `docs/data-model.md` §3）。
5. **不要在生产启用开发鉴权**：`APP_ENV=prod` 缺 `DATABASE_URL`/`JWT_SECRET` 会直接拒绝启动；
   带 Bearer 的请求只认 JWT，只有纯内存 dev/e2e 才允许 `X-Dev-User` 回退。

## 待办（M1）

- [ ] paho MQTT 客户端实现 `mqtt.Bus`，接 `wireIngest`
- [ ] `cmd_ack` 更新 `commands` 状态
- [ ] 绑定限流（同账号 10 次/小时）
- [ ] refresh token / logout / 改密 / 邮箱验证
