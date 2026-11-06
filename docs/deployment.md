# 部署与联调环境

最后验证：2026-11-06。

## 1. 为什么统一用这台公网服务器

车载设备通过 EC800M（Cat.1）上公网，实测拿到的是运营商 **CGNAT 私网地址**（`10.43.x.x`）。
这意味着：

- 设备无法加入开发机/手机所在的局域网；
- 开发机也无法通过局域网主动访问设备；
- 因此所有跨端联调都必须经过一台公网可达的服务器。

**后续开发统一使用 `https://bycicle-locating.top` 作为联调入口。**
服务器地址与 SSH 访问方式放在私有运维记录里，不写入 public 仓库；
私钥、密码、token 同样不写入仓库和文档。

联调脚本、本地 curl 都连接这个域名（App 在 JWT 落地前仍连本机后端）；
不要设计“设备连开发机热点 / 同一 WiFi”的联调流程。

## 2. 访问入口

| 用途 | 地址 | 说明 |
|---|---|---|
| 推荐（HTTPS） | `https://bycicle-locating.top` | Cloudflare Tunnel + Access；未登录会跳转团队登录页 |
| 服务器本机 | `http://127.0.0.1:32525` | 本机调试；nginx 默认只绑回环，不经过 Access |
| 公网直连 | 默认关闭 | 确需时设 `BKL_BIND_ADDR=0.0.0.0`，并在安全组限制来源 IP |

健康检查：`GET /healthz`。公网 `/healthz` 也在 Access 后面；容器健康检查走内网，不受影响。
HTTP API（注册/登录/用户/设备）契约见 [http-api.md](http-api.md)。

- 联调脚本优先使用 `https://bycicle-locating.top`（需 Access 服务令牌）。
  App 目前没有服务令牌/JWT，暂继续连本机后端；JWT 落地后再切到域名。
- 任何公网请求都需要 Cloudflare Access 登录态，或
  `CF-Access-Client-Id` / `CF-Access-Client-Secret` 服务令牌头；当前 App 与固件尚未接入 JWT，
  联调脚本使用服务令牌。
- 固件目前**不走**这个 HTTP 入口：MQTT broker 与后端订阅属 M1，尚未部署。

## 3. 拓扑

```text
客户端 / App ──HTTPS──> Cloudflare 边缘（Access）
                          │  Tunnel（服务器出站连接）
                          ▼
                     cloudflared ──> nginx :8080 ──> backend :8080
服务器本机 ──HTTP:127.0.0.1:32525──> nginx
```

- `backend` 不发布宿主机端口，只存在于 compose 内网；
- nginx 默认只绑 `127.0.0.1`，是唯一入口，负责反向代理、安全响应头与绑定接口限流；
- TLS 由 Cloudflare 终止，nginx 在内网只处理 HTTP；
- `cloudflared` 位于 compose 的 `tunnel` profile，由服务器主动出站，不依赖入站 80/443。

## 4. 服务器与目录

| 项目 | 值 |
|---|---|
| 系统 | Debian 13 x86_64，Docker CE + Compose v2 |
| 代码与编排 | `/opt/bicycle-locating/backend` |
| 环境变量 | `/opt/bicycle-locating/backend/.env`（`0600 root:root`） |
| 关键变量 | `CLAIM_PEPPER`、`TUNNEL_TOKEN`、`POSTGRES_PASSWORD`、`DATABASE_URL`、`JWT_SECRET`、`JWT_TTL`、`CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET`、`BKL_HTTP_PORT=32525`、`BKL_BIND_ADDR=127.0.0.1` |
| 容器 | 默认：`backend`、`nginx`；`tunnel` profile：`cloudflared`；`deps` profile：`postgres`、`migrate`（`broker` 也在 deps，生产不要一起起） |

`.env` 只在服务器上维护，不提交、不复制进仓库。
公网实例**不要设置 `DEV_USER_ID`**——它会让没有 `X-Dev-User` 头的请求也被当成固定用户。

> **当前线上实例仍是 `APP_ENV=dev` + 内存存储**（本次只合入代码，未切换服务器）。
> 切 Postgres/JWT 的步骤在 §5.1；执行前现有域名联调不受影响。切换后要重新注册用户，
> 旧的 `X-Dev-User` 冒烟脚本不再适用。

## 5. 常用操作

```bash
cd /opt/bicycle-locating/backend

# 状态与日志
docker compose ps
docker compose logs -f --tail=100 backend nginx cloudflared

# 更新代码后重建（必须 force-recreate，否则可能继续跑旧镜像）
docker compose up -d --build --force-recreate --wait

# 对正式实例跑全链路冒烟：在开发机（客户端）上执行。
# 服务令牌从服务器 .env 或 Zero Trust 面板取，不要提交。
BASE_URL=https://bycicle-locating.top \
  DEV_USER_ID=11111111-1111-1111-1111-111111111111 \
  CLAIM_CODE="$DEV_SEED_CLAIM" \
  CF_ACCESS_CLIENT_ID=... \
  CF_ACCESS_CLIENT_SECRET=... \
  bash backend/deploy/smoke.sh

# 服务器本机直连 nginx（不经过 Access）
set -a; . ./.env; set +a
BASE_URL=http://127.0.0.1:32525 \
  DEV_USER_ID=11111111-1111-1111-1111-111111111111 \
  CLAIM_CODE="$DEV_SEED_CLAIM" \
  bash deploy/smoke.sh

# 隔离 e2e（独立 project/端口，不碰正式栈；本地不经过 Access）
BKL_E2E_PORT=18080 bash deploy/e2e.sh
```

`deploy/smoke.sh` 在检测到 `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` 时会自动加 Access 头；
未设置时，公网请求会被 302 到团队登录页。

### 5.1 切到 Postgres + JWT（尚未在当前线上实例执行）

代码已支持 Postgres Store 与 JWT；线上实例仍是内存 + dev 鉴权。切换步骤：

```bash
cd /opt/bicycle-locating/backend
# 1. 在 .env 增加（密码含特殊字符时先 URL-encode）：
#    DATABASE_URL=postgres://bkl:<url-encoded-password>@postgres:5432/bike_locating?sslmode=disable
#    JWT_SECRET=<openssl rand -base64 48>，JWT_TTL=24h
#    APP_ENV=prod（JWT 生效后不再接受 X-Dev-User）
# 2. 起库、迁移并重建应用（backend 会等待 migrate 成功）
docker compose --profile deps up -d --build --force-recreate --wait backend nginx
# 3. 从客户端验证用户 API（不能在服务器本机跑域名 smoke）
BASE_URL=https://bycicle-locating.top \
  CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... \
  bash backend/deploy/user-smoke.sh
```

- 迁移 SQL 在 `internal/store/migrations/`；`migrate` 是一次性容器，失败会退出非零。
- 启用 `deps` profile 时，`backend` 的 `depends_on` 会等待 `migrate` 成功后再启动；
  纯内存 profile 没有 `migrate`，依赖标了 `required:false`，不影响默认 `up`。
- 数据库卷是 `pg-data`；`docker compose down -v` 会删除全部用户/绑定/轨迹，生产禁用。
- 备份：`docker compose --profile deps exec -T postgres pg_dump -U bkl bike_locating > backup.sql`。
- `POSTGRES_PASSWORD` 只在首次初始化数据卷时生效；之后改 `.env` 不会改已有库密码。

## 6. 域名、Tunnel 与 Access

- 隧道名：`bicycle-locating`；连接器是 compose 服务 `cloudflared`。
- Public Hostname：`bycicle-locating.top` → `http://nginx:8080`。
- DNS：`bycicle-locating.top` 是指向隧道的**代理 CNAME**，不再保留指向源站的 A 记录。
- 为什么用 Tunnel：源站在中国大陆且域名未备案时，阿里云会按 Host 在入站侧拦截
  （80/8080/32525 都试过，换非标端口无效）；普通 Cloudflare 代理回源同样被拦。
  Tunnel 由服务器主动出站到 Cloudflare，绕开入站检查，同时提供 443 证书。
- 隧道 token 只存在服务器 `.env`。需要轮换时在 Cloudflare 隧道详情点“轮换令牌”，
  更新 `.env` 后 `docker compose --profile tunnel up -d --force-recreate cloudflared`。

### Cloudflare Access（已启用）

- 应用：`bicycle-locating-api`，自托管，目标 `bycicle-locating.top`（全路径）。
- 策略：
  - `owner-email`（Allow）：联调成员邮箱（在 Zero Trust 面板维护，不写入仓库）；
  - `service-token`（Service Auth）：服务令牌 `bkl-dev-smoke`（有效期 1 年）。
- 未带登录态或令牌的请求返回 302，跳转
  `https://crimson-shadow-fd5f.cloudflareaccess.com/cdn-cgi/access/login/...`。
- 服务令牌的 Client ID / Secret 只存在于服务器 `.env`（`0600`），不写入仓库、文档或 CI。
  轮换方式：Zero Trust → Access → Service credentials → 新建令牌 → 更新 `.env`
  → 更新 Access 策略中的令牌引用。
- 从服务器本机跑域名 smoke 可能因服务器出站到 Cloudflare 的回程丢响应而超时；
  正式验证应**从开发机/客户端**执行，服务器本机用 `http://127.0.0.1:32525` 直连 nginx。
- Access 只是边缘收口，不能替代应用自己的 JWT；当前线上仍是 `APP_ENV=dev` + 内存，
  切到 `APP_ENV=prod` 后只认 JWT，`X-Dev-User` 回退会关闭。

## 7. 当前限制

- **线上实例仍是 `APP_ENV=dev` + 内存存储**：代码已支持 JWT/Postgres，但本次没有切换服务器。
  无头请求返回 401，带任意 `X-Dev-User` 仍会被信任；不要放真实用户数据。
- 切 `APP_ENV=prod` 必须同时配置 `DATABASE_URL` 与 `JWT_SECRET`，否则服务拒绝启动；
  配置 `DATABASE_URL` 后也不能沿用公开的开发默认 JWT secret，否则同样拒绝启动。
- 公网入口已加 Access：浏览器需邮箱登录，脚本需服务令牌；App/固件还没有接入 JWT，
  因此暂不能直接访问这个 HTTP 入口。
- 服务令牌 `bkl-dev-smoke` 有效期到 2027-11-06，到期前需轮换。
- nginx 对绑定接口限流（每真实客户端 IP 1 r/s，burst 5），对 `/v1/auth/` 限流
  （1 r/s，burst 3）；超出返回 429 JSON。业务级登录风控仍属 M1。
- JWT 目前没有 refresh token / logout / 改密 / 邮箱验证；token 过期后重新登录。
- 存储：线上内存实现重启即丢；Postgres 模式持久化在 `pg-data` 卷。
- MQTT 仍是日志桩；固件上报链路（broker + TLS + 每设备 ACL）属 M1。
