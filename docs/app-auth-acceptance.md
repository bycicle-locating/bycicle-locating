# App 账号与车辆验收

## 当前验证状态

2026-11-13：新版后端已上传到服务器独立目录 `/opt/bkl-auth-validation-20261113`。
运行 `GOPROXY=https://goproxy.cn,direct bash deploy/e2e-postgres.sh` 通过：Postgres 迁移、注册、JWT 用户查询、修改资料、车辆列表、绑定、解绑、解绑后拒绝访问、认证限流。测试栈已由脚本清理。Store 集成单测未运行（服务器宿主没有 Go）。

正式入口已切到 Postgres + JWT（APP_ENV=prod）：匿名访问 `/v1/users/me` 返回 401。服务器经公网 HTTPS 域名、使用 Access 服务令牌执行用户冒烟通过：健康检查、注册、用户查询、修改资料和车辆列表。尚未完成开发机外部请求和手机端验收；上述结果不代表手机 Access 已配置。

## 手机访问方案

App 默认请求 `https://bycicle-locating.top`。Cloudflare Access 和应用 JWT 分别校验开发团队身份与车主账号；App 不包含 Access 服务令牌。

开发手机使用 Cloudflare One Client 的组织会话身份：

1. 在 Zero Trust 的设备注册策略中允许测试成员邮箱，启用 Cloudflare One Client 会话身份认证。
2. 在现有 Access 应用启用 **Authenticate with Cloudflare One Client**，保留成员邮箱限制。确认目标域名流量经过组织 Gateway，没有被 Split Tunnels 排除。
3. 手机安装 Cloudflare One Client，加入对应 Zero Trust 组织，使用获准邮箱登录并连接。
4. 打开 App 注册或登录。浏览器 Access 登录不会自动授权原生 App 的 HTTP 请求。

这需要 Cloudflare 控制台管理员操作或管理 API 凭据；服务器上的 Tunnel token 和 Service Auth token 不提供此管理权限。本次未修改 Access 策略，也未完成手机组织注册。

参考：https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/client-sessions/

## 正式后端切换

已获准丢弃旧开发实例的内存数据，并完成切换。原部署文件及 `.env` 已备份在服务器 `/opt/bicycle-locating/backup-auth-*`，备份目录仅 root 可访问。

新实例使用独立随机 JWT secret、Postgres 密码，保留 CLAIM_PEPPER，设置 APP_ENV=prod，清空开发身份和种子配置，运行迁移后重建 backend/nginx。数据库卷不得删除；文件备份不能恢复旧进程的内存数据。

## 公网验收顺序

1. 从开发机通过 SSH 取得仅在服务器内使用的服务认证环境，执行服务器上的 `deploy/user-smoke.sh`，BASE_URL 指向公网 HTTPS 域名。密钥不得写入 App、日志或版本库。
2. 服务器请求公网可验证 Tunnel/Access/API，但还须从开发机执行外部请求，确认客户端到公网链路。
3. 无应用 JWT 时，业务接口必须返回 401；伪造、过期 JWT 同样返回 401。注册/登录允许匿名调用。
4. 手机已连接组织 One Client 时，未登录只能看到登录/注册；直接进入地图、骑行、车辆、设置、绑定页均应回到登录页。
5. 登录 → 空车辆列表 → 用专用测试设备声明码绑定 → 首页和车辆页同步 → 重启恢复会话 → 确认解绑 → 列表刷新。
6. 账号 A 退出后登录 B，不得显示 A 的车辆；无权解绑应提示失败并保留列表。
7. 关闭 One Client 或撤销 Access 身份后应提示访问授权失败，不能误报绑定成功；恢复访问后可重试。
8. JWT 到期或服务端返回认证失败后回登录页。NFC 绑定链接登录后恢复原设备编号与声明码。

验收使用专用账号和设备，不解绑实际用户车辆。真实地图、NFC/BLE 插件和 iOS 打包不属于本轮验收。
