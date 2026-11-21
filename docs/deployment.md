# 部署与联调环境

## 1. 访问入口

| 用途 | 地址 | 鉴权 |
|---|---|---|
| App 公网 API | `https://api.bycicle-locating.top` | 健康检查、注册和登录可匿名访问；用户与车辆接口使用 Bearer JWT |
| 车载 MQTT | `mqtts://mqtt.bycicle-locating.top:8883` | 私有 CA、每设备独立凭据和主题权限 |
| 团队联调 | `https://bycicle-locating.top` | Cloudflare Access。浏览器使用团队邮箱，脚本使用服务令牌。业务接口仍校验 JWT |
| 服务器本机 | `http://127.0.0.1:32525` | 直连 nginx，业务接口仍校验 JWT |

App 默认使用公网 API。访问流程和错误响应见 [HTTP API](http-api.md)。

车载设备通过 EC800M 蜂窝网络主动连公网 Mosquitto。公网 TLS 入口已验证可达，服务器侧已验证专用设备发布与后端账号订阅。EC800M 经真实 4G 上报待验收。服务器地址与 SSH 访问方式见私有运维记录。

## 2. 部署拓扑

```text
App ──HTTPS──> api.bycicle-locating.top ───────────┐
团队 ─HTTPS──> bycicle-locating.top（Access） ─────┤
                                                 ▼
                                  Cloudflare Tunnel → nginx → backend → PostgreSQL
服务器本机 ──────────────────HTTP 127.0.0.1:32525─────> nginx
```

- 两个域名都通过 Cloudflare Tunnel 指向 `http://nginx:8080`，由 Cloudflare 终止 TLS。源站的 nginx 端口默认绑定回环地址，backend 只接入 Compose 内网。
- Access 策略覆盖团队域名，公开 API 域名由应用使用 JWT 鉴权。Access 服务令牌仅用于团队入口，由服务器的私有环境变量管理。
- nginx 按客户端 IP 限流。绑定接口为 1 次/秒、突发 5 次，注册与登录接口为 1 次/秒、突发 3 次。超限返回 `429 rate_limited`。

## 3. 生产部署与维护

生产实例使用 `APP_ENV=prod` 和 Postgres。部署目录为 `/opt/bicycle-locating/backend`，私有配置保存在该目录的 `.env`（`0600 root:root`）。

| 配置 | 用途 |
|---|---|
| `APP_ENV=prod` | 业务接口使用 JWT 鉴权 |
| `DATABASE_URL`、`POSTGRES_PASSWORD` | Postgres 连接及新数据卷初始化；Compose 内的数据库主机名为 `postgres`，URL 中的密码需编码 |
| `JWT_SECRET`、`JWT_TTL` | 至少 32 字节的独立签名密钥和会话有效期 |
| `CLAIM_PEPPER` | 设备声明码 HMAC |
| `TUNNEL_TOKEN` | Cloudflare Tunnel 连接器凭据 |
| `CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET` | 团队入口的联调脚本凭据 |
| `BKL_BIND_ADDR=127.0.0.1`、`BKL_HTTP_PORT=32525` | nginx 在服务器上的监听地址与端口 |
| `MQTT_URL`、`MQTT_USER`、`MQTT_PASSWORD` | 生产必填。使用上表的 TLS Broker 地址和后端专用账号 |
| `MQTT_CA_FILE`、`MQTT_CLIENT_ID` | 私有 CA 容器路径为 `/run/bkl/mqtt/mqtt-ca.crt`，默认客户端 ID 为 `bkl-backend` |

升级后端前先填 MQTT 配置并准备 [公共 CA 证书](../backend/deploy/certs/mqtt-ca.crt)。默认源目录为
`backend/deploy/certs`，设备和后端使用同一份信任根。生产 Broker 独立部署，`deps` 中的匿名 Broker 用于本地开发。

```bash
cd /opt/bicycle-locating/backend

docker compose --profile deps --profile tunnel ps
docker compose logs -f --tail=100 backend nginx cloudflared

# 更新后端并等待服务就绪
docker compose --profile deps up -d --build --wait backend nginx

# 启动隧道连接器
docker compose --profile tunnel up -d cloudflared

# 备份数据库
docker compose --profile deps exec -T postgres pg_dump -U bkl bike_locating > backup.sql
```

启动 Postgres 模式时，`migrate` 先执行 `internal/store/migrations/` 中的迁移，后端启动时再校验表结构。生产数据保存在 `pg-data` 卷，维护和重建容器时须保留该卷。`POSTGRES_PASSWORD` 在首次初始化数据卷时生效。

新设备须先[登记设备编号和声明码](../backend/README.md#设备登记)，再用该编号配置 Broker 凭据和 ACL。
当前车主可通过公网 [位置与轨迹接口](http-api.md#31-最新位置与轨迹) 查看本次绑定期间的有效定位点。

在 Cloudflare Zero Trust 中维护团队邮箱和 Access 服务令牌。轮换服务令牌时，将新凭据写入服务器 `.env`，再更新 Access 策略的令牌引用。轮换 Tunnel 凭据后，更新 `TUNNEL_TOKEN` 并重建 `cloudflared`。

## 4. 联通验证

从开发机执行以下只读检查。服务器本机可用 `http://127.0.0.1:32525/healthz` 直连 nginx。

在仓库根目录执行下列命令，检查 API 健康状态与遥测路由的匿名鉴权。

```bash
BASE_URL=https://api.bycicle-locating.top bash backend/deploy/telemetry-smoke.sh
```

通过条件是 `/healthz` 返回 `200` 与 `status: ok`，位置和轨迹接口均返回 `401 unauthenticated`。
如果上述匿名检查返回 `404`，核对当前运行的后端版本与代理路由。

2026-11-21，生产后端部署 [`e00641c`](https://github.com/bycicle-locating/bycicle-locating/commit/e00641ccf9860e8bebbf764c798282a5054471cc) 后，通过 MQTT TLS 连接生产 Broker 并完成 `telemetry`、`event`、`status` 和 `cmd/ack` 订阅。开发机对公网 API 执行上述检查，三项均通过。

使用 [隔离联调脚本](../backend/deploy/e2e-mqtt.sh) 可复现 MQTT 模拟上报、Postgres 入库、带 JWT 的车主查询和换绑隔离。

```bash
curl -fsS https://api.bycicle-locating.top/healthz
curl -sS -i https://api.bycicle-locating.top/v1/users/me
curl -sS -i https://api.bycicle-locating.top/v1/users/me/devices
curl -sS -i https://bycicle-locating.top/healthz
```

2026-11-20 实测，公开 API 的 `/healthz` 返回 `200` 和 `{"status":"ok"}`，匿名访问用户与车辆列表返回 `401 unauthenticated`，团队入口的 `/healthz` 返回 Access `302`。Flutter `ApiClient` 使用默认地址时也收到了预期的 JSON 鉴权响应。

2026-11-20，使用同一版 Flutter `ApiClient` 连本地隔离的 Postgres 测试栈，通过了注册、登录、Bearer 鉴权、车辆列表、绑定、详情和解绑。可用 `backend/deploy/e2e-postgres.sh` 复现后端的 Postgres 栈冒烟。

2026-11-13，Android 模拟器已通过公网完成注册、登录、会话恢复、绑定和解绑。真机验收见 [Issue #15](https://github.com/bycicle-locating/bycicle-locating/issues/15)。 [App 验收记录](app-auth-acceptance.md)

2026-11-20，服务器本机通过 MQTT TLS 1.2 与 1.3 严格校验，开发机公网实测 TLS 1.3 通过。
开发机公网 TLS 1.2 握手被重置，仍需用 EC800M 在蜂窝网上实测。

实车联调使用专用测试设备和账号。实车在室外开机后，确认 App 地图在 5 分钟内显示首个真实定位点。记录该点的 `seq`、UTC 采样时间和 App 版本。在联调环境重启后端，确认当前车主仍能查询该点。
