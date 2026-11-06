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
| 推荐（HTTPS） | `https://bycicle-locating.top` | Cloudflare Tunnel，服务器主动出站 |
| 服务器本机 | `http://127.0.0.1:32525` | 本机调试；nginx 默认只绑回环 |
| 公网直连 | 默认关闭 | 确需时设 `BKL_BIND_ADDR=0.0.0.0`，并在安全组限制来源 IP |

健康检查：`GET /healthz`。

- App 的 API base URL、联调脚本优先使用 `https://bycicle-locating.top`。
- 固件目前**不走**这个 HTTP 入口：MQTT broker 与后端订阅属 M1，尚未部署。

## 3. 拓扑

```text
客户端 / App ──HTTPS──> Cloudflare 边缘
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
| 关键变量 | `CLAIM_PEPPER`、`TUNNEL_TOKEN`、`POSTGRES_PASSWORD`、`BKL_HTTP_PORT=32525`、`BKL_BIND_ADDR=127.0.0.1` |
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

# 对正式实例跑全链路冒烟（经域名；显式带 dev 身份头）
set -a; . ./.env; set +a
BASE_URL=https://bycicle-locating.top \
  DEV_USER_ID=11111111-1111-1111-1111-111111111111 \
  CLAIM_CODE="$DEV_SEED_CLAIM" \
  bash deploy/smoke.sh

# 隔离 e2e（独立 project/端口，不碰正式栈）
BKL_E2E_PORT=18080 bash deploy/e2e.sh
```

如果启用了 Cloudflare Access，`.env` 里的 `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`
会被 `smoke.sh` 自动带到请求头里；e2e 在本地不经过 Access，不需要它们。

## 6. 域名、Tunnel 与 Access

- 隧道名：`bicycle-locating`；连接器是 compose 服务 `cloudflared`。
- Public Hostname：`bycicle-locating.top` → `http://nginx:8080`。
- DNS：`bycicle-locating.top` 是指向隧道的**代理 CNAME**，不再保留指向源站的 A 记录。
- 为什么用 Tunnel：源站在中国大陆且域名未备案时，阿里云会按 Host 在入站侧拦截
  （80/8080/32525 都试过，换非标端口无效）；普通 Cloudflare 代理回源同样被拦。
  Tunnel 由服务器主动出站到 Cloudflare，绕开入站检查，同时提供 443 证书。
- 隧道 token 只存在服务器 `.env`。需要轮换时在 Cloudflare 隧道详情点“轮换令牌”，
  更新 `.env` 后 `docker compose --profile tunnel up -d --force-recreate cloudflared`。
- 建议在 Cloudflare Zero Trust 为 `bycicle-locating.top` 加 Access 策略：只放行车主邮箱与
  联调服务令牌。启用后 `smoke.sh` 会自动带 `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET`。
  Access 只是边缘收口，不能替代 M1 的 JWT。
- 当前公网实例已移除 `DEV_USER_ID` 回退：无头请求返回 401，但带任意 `X-Dev-User` 仍会被信任。

## 7. 当前限制

- `APP_ENV=dev`：JWT 尚未实现。公网实例不设 `DEV_USER_ID` 后，无头请求返回 401，
  但带任意 `X-Dev-User` 仍会被信任；不要放真实用户数据。
- nginx 对 `POST /v1/devices:bind` 做基础限流（每真实客户端 IP 1 r/s，burst 5）；
  业务级绑定限流仍属 M1。
- 存储是内存实现，重启后数据全部丢失。
- MQTT 仍是日志桩；固件上报链路（broker + TLS + 每设备 ACL）属 M1。
