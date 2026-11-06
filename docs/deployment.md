# 部署与联调环境

最后验证：2026-11-06。

## 1. 为什么统一用这台公网服务器

车载设备通过 EC800M（Cat.1）上公网，实测拿到的是运营商 **CGNAT 私网地址**（`10.43.x.x`）。
这意味着：

- 设备无法加入开发机/手机所在的局域网；
- 开发机也无法通过局域网主动访问设备；
- 因此所有跨端联调都必须经过一台公网可达的服务器。

**后续开发统一使用 `8.152.6.221` 作为联调服务器。**
App、固件测试脚本、本地 curl 都连接这台机器暴露的地址；
不要设计"设备连开发机热点 / 同一 WiFi"的联调流程。

SSH：`ssh root@8.152.6.221`（已配置公钥免密）。
私钥、密码、token 不写入仓库和文档。

## 2. 访问入口

| 用途 | 地址 | 说明 |
|---|---|---|
| 推荐（HTTPS） | `https://bycicle-locating.top` | Cloudflare Tunnel，服务器主动出站 |
| 直连 IP（HTTP） | `http://8.152.6.221:32525` | 备用入口，明文无证书 |
| 服务器本机 | `http://127.0.0.1:32525` | 本机调试 |

健康检查：`GET /healthz`。

- App 的 API base URL、联调脚本优先使用 `https://bycicle-locating.top`。
- 固件目前**不走**这个 HTTP 入口：MQTT broker 与后端订阅属 M1，尚未部署。

## 3. 拓扑

```text
客户端 / App ──HTTPS──> Cloudflare 边缘
                          │  Tunnel（服务器出站连接）
                          ▼
                     cloudflared ──> nginx :8080 ──> backend :8080
直连客户端 ──HTTP:32525──> nginx（宿主机发布端口）
```

- `backend` 不发布宿主机端口，只存在于 compose 内网；
- nginx 是唯一入口，负责反向代理与安全响应头；
- `cloudflared` 位于 compose 的 `tunnel` profile，由服务器主动出站，不依赖入站 80/443。

## 4. 服务器与目录

| 项目 | 值 |
|---|---|
| 系统 | Debian 13 x86_64，Docker CE + Compose v2 |
| 代码与编排 | `/opt/bicycle-locating/backend` |
| 环境变量 | `/opt/bicycle-locating/backend/.env`（`0600 root:root`） |
| 关键变量 | `CLAIM_PEPPER`、`TUNNEL_TOKEN`、`BKL_HTTP_PORT=32525` |
| 容器 | `backend`、`nginx`、`cloudflared`（`tunnel` profile） |

`.env` 只在服务器上维护，不提交、不复制进仓库。

## 5. 常用操作

```bash
cd /opt/bicycle-locating/backend

# 状态与日志
docker compose ps
docker compose logs -f --tail=100 backend nginx cloudflared

# 更新代码后重建（必须 force-recreate，否则可能继续跑旧镜像）
docker compose up -d --build --force-recreate --wait

# 对正式实例跑全链路冒烟（经域名）
set -a; . ./.env; set +a
BASE_URL=https://bycicle-locating.top CLAIM_CODE="$DEV_SEED_CLAIM" bash deploy/smoke.sh

# 隔离 e2e（独立 project/端口，不碰正式栈）
BKL_E2E_PORT=18080 bash deploy/e2e.sh
```

## 6. 域名与 Cloudflare Tunnel

- 隧道名：`bicycle-locating`；连接器是 compose 服务 `cloudflared`。
- Public Hostname：`bycicle-locating.top` → `http://nginx:8080`。
- DNS：`bycicle-locating.top` 是指向隧道的**代理 CNAME**，不再保留指向源站的 A 记录。
- 为什么用 Tunnel：源站在中国大陆且域名未备案时，阿里云会按 Host 在入站侧拦截
  （80/8080/32525 都试过，换非标端口无效）；普通 Cloudflare 代理回源同样被拦。
  Tunnel 由服务器主动出站到 Cloudflare，绕开入站检查，同时提供 443 证书。
- 隧道 token 只存在服务器 `.env`。需要轮换时在 Cloudflare 隧道详情点“轮换令牌”，
  更新 `.env` 后 `docker compose --profile tunnel up -d --force-recreate cloudflared`。

## 7. 当前限制

- `APP_ENV=dev`：JWT 尚未实现，`X-Dev-User` 即身份；公网可达，严禁放真实用户数据。
- 存储是内存实现，重启后数据全部丢失。
- MQTT 仍是日志桩；固件上报链路（broker + TLS + 每设备 ACL）属 M1。
- 服务器同时保留直连 `:32525`；如果只允许走域名，可在安全组收紧该端口。
