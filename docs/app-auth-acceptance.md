# App 账号与车辆验收

## 当前验证状态

2026-11-13：新版后端已上传到服务器独立目录 `/opt/bkl-auth-validation-20261113`。
运行 `GOPROXY=https://goproxy.cn,direct bash deploy/e2e-postgres.sh` 通过：Postgres 迁移、注册、JWT 用户查询、修改资料、车辆列表、绑定、解绑、解绑后拒绝访问、认证限流。测试栈已由脚本清理。Store 集成单测未运行（服务器宿主没有 Go）。

正式入口已切到 Postgres + JWT（APP_ENV=prod）。管理员配置公开 API 域名后，已从开发机不携带 Access 凭据执行 `BASE_URL=https://api.bycicle-locating.top bash backend/deploy/user-smoke.sh`，健康检查、注册、JWT 用户查询、修改资料和车辆列表通过。匿名、伪造 JWT、仅带开发身份头访问 `/v1/users/me` 均返回 401；公开域名 `/admin` 返回 404，原受保护域名 `/healthz` 仍返回 302。尚未完成手机真机完整闭环验收。

### Android 模拟器实测

2026-11-13：构建 debug APK 并安装到 `medium_phone` 模拟器，通过公开 API 完成注册、已有账号登录、杀进程后恢复会话、退出后重启仍显示登录页。使用专用虚拟设备 `BKL-TEST-20261113-0837` 完成手动绑定，车辆页与首页同步显示设备编号；确认解绑后车辆列表恢复为空。

测试设备不对应物理硬件，验收后保持未绑定状态，保留测试账号和绑定审计记录。以上是 Android 模拟器实测，不代表物理手机、NFC/BLE、设备指令确认已验证。

界面重绘后在模拟器复核了浅/深色、面板收起与展开、浮动绑定/车辆管理/设置卡片及键盘避让。自动化测试新增覆盖：切换账号后不保留上一账号车辆与选择、绑定失败保留输入、损坏会话清理。物理手机、真实令牌到期计时与 VoiceOver 完整走查仍未验证。

## 普通用户公网访问方案

普通用户安装 App 后直接注册、登录，无需安装 Cloudflare One Client、加入 Zero Trust 组织或由管理员逐个放行邮箱。One Client 仅可作为开发团队的联调方式，不是产品使用前提。

### 入口与权限

- App API 使用独立域名 `https://api.bycicle-locating.top`，经 Cloudflare 代理和现有 Tunnel 转发到 nginx，再到后端。该入口不设置团队邮箱 Access 门禁，也不依赖 Access 服务令牌。
- 原有 `https://bycicle-locating.top` 保留 Access 保护，供开发团队访问；将来的管理接口只能通过受保护入口访问，不能因共用后端而暴露在公开 API 域名下。目前没有新增管理接口。
- 注册、登录接口允许匿名请求；车辆、个人资料等业务接口必须校验有效 JWT，车辆读写还必须校验车主权限。App 未登录时只能访问登录、注册页面。
- 保留 HTTPS、认证和绑定限流、载荷限制及后端权限校验。源站端口继续仅绑定回环地址，通过 Tunnel 接入，不新增公网直连端口。
- App 不保存 Cloudflare 服务令牌；用户 JWT 继续存入系统安全存储。

### 实施顺序

1. 配置 API 子域名的 DNS 和 Tunnel 路由，确认现有通配符 Access 策略不会覆盖该域名；原域名的 Access 策略保留。
2. 检查 nginx 在公开域名只暴露产品 API 和必要健康检查，未知路径拒绝访问；确认部署为 APP_ENV=prod，开发身份头不能授予权限。
3. 从开发机在不携带 Access cookie、服务令牌且未连接 One Client 的条件下，完成下列公网验收。
4. 验收通过后，将 App 默认 API 地址切换到 `https://api.bycicle-locating.top` 并重新构建。WebSocket 尚未实现，不因本方案宣称其可用。

管理员已在控制台配置公开 API 入口，开发机外部冒烟通过，App 默认地址已切换到 `https://api.bycicle-locating.top`。本 PR 未修改 Cloudflare 配置；仍需真机验证登录、会话恢复与测试设备绑定/解绑。

## 正式后端切换

已获准丢弃旧开发实例的内存数据，并完成切换。原部署文件及 `.env` 已备份在服务器 `/opt/bicycle-locating/backup-auth-*`，备份目录仅 root 可访问。

新实例使用独立随机 JWT secret、Postgres 密码，保留 CLAIM_PEPPER，设置 APP_ENV=prod，清空开发身份和种子配置，运行迁移后重建 backend/nginx。数据库卷不得删除；文件备份不能恢复旧进程的内存数据。

## 公网验收顺序

1. 在开发机断开 One Client，不携带 Access cookie 或服务令牌，以 `BASE_URL=https://api.bycicle-locating.top` 运行 `backend/deploy/user-smoke.sh`；确认响应为 API JSON，没有跳转 Access 登录页。
2. 从普通手机网络重复注册、登录，验证有效 TLS 和外部客户端链路；原受保护域名仍须拒绝未授权访问。
3. 无应用 JWT、伪造或过期 JWT 访问业务接口必须返回 401；仅带 `X-Dev-User` 同样返回 401。注册/登录允许匿名调用，重复认证请求须触发限流。
4. 手机无需 One Client，未登录只能看到登录/注册；直接进入地图、骑行、车辆、设置、绑定页均应回到登录页。
5. 登录 → 空车辆列表 → 用专用测试设备声明码绑定 → 首页和车辆页同步 → 重启恢复会话 → 确认解绑 → 列表刷新。
6. 账号 A 退出后登录 B，不得显示 A 的车辆；无权解绑应提示失败并保留列表。
7. 断网或请求失败时显示错误并可重试，不得误报绑定或解绑成功；以账号 B 请求账号 A 的车辆详情或解绑必须被服务端拒绝。
8. JWT 到期或服务端返回认证失败后回登录页。NFC 绑定链接登录后恢复原设备编号与声明码。

验收使用专用账号和设备，不解绑实际用户车辆。真实地图、NFC/BLE 插件和 iOS 打包不属于本轮验收。
