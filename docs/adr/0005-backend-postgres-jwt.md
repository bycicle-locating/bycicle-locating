# ADR-0005：后端引入 Postgres 与 JWT

状态：已接受（2026-11-06）

## 背景

M0 后端只有内存 Store 与开发鉴权（`X-Dev-User`），`users` 表只存在于数据模型。
M1 需要真实账号、持久化绑定与可验证的 App 鉴权；App 登录页也已预留
`POST /v1/auth/login`。

原骨架刻意保持零第三方依赖，但用户表要求 `password_hash` 使用 argon2id，
Postgres 访问也需要驱动。继续用内存或自实现密码学都会把复杂度转移到更危险的地方。

## 决定

1. **Postgres 驱动使用 `github.com/jackc/pgx/v5`**，只出现在 `internal/store` 实现内；
   `store.Store` 接口不暴露 pgx 类型。
2. **密码哈希使用 `golang.org/x/crypto/argon2`**，参数为 m=64 MiB、t=3、p=2，
   编码格式 `argon2id$v=19$...`。
3. **JWT 用标准库实现 HS256**（`crypto/hmac` + `encoding/base64`），不引入 JWT 库；
   严格拒绝 `alg=none` 与其他算法。
4. **迁移由一次性 `migrate` 容器用 `psql` 执行**，SQL 放在
   `internal/store/migrations/`；应用启动只检查版本与关键表，不动态执行 SQL。
5. 保留内存 Store 作为 dev/e2e 路径；`APP_ENV=prod` 强制 `DATABASE_URL` 与 `JWT_SECRET`；
   配置 `DATABASE_URL` 后也不允许使用公开的开发默认 JWT secret。

## 后果

- 首次 `go build` / Docker 构建需要下载模块；服务器可用 `GOPROXY=https://goproxy.cn,direct`。
- 依赖面从 0 增加到 pgx + x/crypto（及其传递依赖），换来了标准 Postgres 访问与
  经过审计的密码哈希实现。
- 迁移不在应用启动时执行：`deps` profile 下由一次性 `migrate` 服务完成，`backend` 等待其
  成功后启动；好处是只读根文件系统与最小权限容器不需要写迁移状态。
- 仍未实现 refresh token、logout、改密、邮箱验证；这些是后续身份能力，不影响本决定。

## 未采用

- `lib/pq`：维护活跃度与类型支持不如 pgx，且同样需要第三方依赖。
- 标准库 PBKDF2：能保持零依赖，但数据模型已明确 argon2id；为省一个依赖降低密码哈希强度不值得。
- JWT 第三方库：HS256 的签发/校验很小，标准库实现可控且减少供应链面。
