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

App、固件测试脚本、本地 curl 都连接这个域名；
不要设计“设备连开发机热点 / 同一 WiFi”的联调流程。

## 2. 访问入口

| 用途 | 地址 | 说明 |
|---|---|---|
| 推荐（HTTPS） | `https://bycicle-locating.top` | Cloudflare Tunnel + Access；未登录会跳转团队登录页 |
| 服务器本机 | `http://127.0.0.1:32525` | 本机调试；nginx 默认只绑回环，不经过 Access |
| 公网直连 | 默认关闭 | 确需时设 `BKL_BIND_ADDR=0.0.0.0`，并在安全组限制来源 IP |

健康检查：`GET /healthz`。公网 `/healthz` 也在 Access 后面；容器健康检查走内网，不受影响。

- App 的 API base URL、联调脚本优先使用 `https://bycicle-locating.top`。
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
| 关键变量 | `CLAIM_PEPPER`、`TUNNEL_TOKEN`、`POSTGRES_PASSWORD`、`CF_ACCESS_CLIENT_ID`、`CF_ACCESS_CLIENT_SECRET`、`BKL_HTTP_PORT=32525`、`BKL_BIND_ADDR=127.0.0.1` |
| 容器 | `backend`、`nginx`、`cloudflared`（`tunnel` profile） |

`.env` 只在服务器上维护，不提交、不复制进仓库。
公网实例**不要设置 `DEV_USER_ID`**——它会让没有 `X-Dev-User` 头的请求也被当成固定用户。

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
  - `owner-email`（Allow）：`Hesitate-p@outlook.com`；
  - `service-token`（Service Auth）：服务令牌 `bkl-dev-smoke`（有效期 1 年）。
- 未带登录态或令牌的请求返回 302，跳转
  `https://crimson-shadow-fd5f.cloudflareaccess.com/cdn-cgi/access/login/...`。
- 服务令牌的 Client ID / Secret 只存在于服务器 `.env`（`0600`），不写入仓库、文档或 CI。
  轮换方式：Zero Trust → Access → Service credentials → 新建令牌 → 更新 `.env`
  → 更新 Access 策略中的令牌引用。
- 从服务器本机跑域名 smoke 可能因服务器出站到 Cloudflare 的回程丢响应而超时；
  正式验证应**从开发机/客户端**执行，服务器本机用 `http://127.0.0.1:32525` 直连 nginx。
- Access 只是边缘收口，不能替代 M1 的 JWT；`APP_ENV=dev` 下带任意 `X-Dev-User`
  仍会被信任，不要把真实用户数据放到这个实例。

## 7. 当前限制

- `APP_ENV=dev`：JWT 尚未实现。公网实例不设 `DEV_USER_ID` 后，无头请求返回 401，
  但带任意 `X-Dev-User` 仍会被信任；不要放真实用户数据。
- 公网入口已加 Access：浏览器需邮箱登录，脚本需服务令牌；App/固件还没有 JWT，
  因此暂不能直接访问这个 HTTP 入口。
- 服务令牌 `bkl-dev-smoke` 有效期到 2027-11-06，到期前需轮换。
- nginx 对 `POST /v1/devices:bind` 做基础限流（每真实客户端 IP 1 r/s，burst 5）；
  业务级绑定限流仍属 M1。
- 存储是内存实现，重启后数据全部丢失。
- MQTT 仍是日志桩；固件上报链路（broker + TLS + 每设备 ACL）属 M1。
