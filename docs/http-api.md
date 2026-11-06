# HTTP API

面向 App 的 JSON API。设备↔云协议见 [protocol.md](protocol.md)，设备绑定安全语义见 [pairing.md](pairing.md)。

- Base URL：`https://bycicle-locating.top`
- 编码：UTF-8 JSON；请求必须带 `Content-Type: application/json`
- 时间：UTC RFC3339（如 `2026-11-06T12:00:00Z`）
- 单位：位置 m、速度 m/s、航向度、海拔 m；km/h 只在 UI 出现
- 鉴权：除 `/healthz`、注册、登录外，全部需要 `Authorization: Bearer <JWT>`

## 1. 错误格式

所有错误响应统一为两个字符串字段：

```json
{"error":"invalid_credentials","message":"邮箱或密码错误"}
```

| HTTP | `error` | 含义 |
|---|---|---|
| 400 | `bad_request` | 请求体格式错误或字段缺失 |
| 400 | `invalid_email` | 邮箱格式不合法 |
| 400 | `weak_password` | 密码长度不符合要求 |
| 401 | `invalid_credentials` | 邮箱或密码错误（不区分账号是否存在） |
| 401 | `unauthenticated` | 缺少、无效或过期的 Bearer token |
| 403 | `invalid_claim` | 声明码错误，或设备不存在（两者对外一致） |
| 403 | `forbidden` | 已登录但无权操作该资源 |
| 404 | `not_found` | 资源不存在 |
| 409 | `already_bound` | 设备已被绑定 |
| 409 | `email_taken` | 注册邮箱已被占用 |
| 429 | `rate_limited` | 请求过于频繁 |
| 500 | `internal` | 服务暂时不可用；细节只进服务端日志 |

## 2. 用户

### 2.1 注册

`POST /v1/auth/register`（无鉴权）

```json
{"email":"rider@example.com","password":"至少 8 个字符","displayName":"通勤车"}
```

- `email` 会 trim 并转小写；最长 254 字节。
- `password` 8–128 字节，不做复杂度规则。
- `displayName` 可选，最长 64 个字符；空字符串视为未设置。
- 邮箱已存在返回 `409 email_taken`；注册场景必然暴露邮箱占用，这是已知取舍。
- 成功 `201`：

```json
{
  "token": "<JWT>",
  "expiresAt": "2026-11-07T12:00:00Z",
  "user": {
    "id": "9f1c2f3a-4b5c-4d6e-8f70-1a2b3c4d5e6f",
    "email": "rider@example.com",
    "displayName": "通勤车",
    "createdAt": "2026-11-06T12:00:00Z"
  }
}
```

### 2.2 登录

`POST /v1/auth/login`（无鉴权）

```json
{"email":"rider@example.com","password":"至少 8 个字符"}
```

- 成功 `200`，响应结构与注册相同。
- 邮箱不存在与密码错误都返回 `401 invalid_credentials`，不泄露账号是否存在。
- 当前没有 refresh token；token 过期后重新登录。

### 2.3 当前用户

`GET /v1/users/me`（Bearer）

```json
{
  "id": "9f1c2f3a-4b5c-4d6e-8f70-1a2b3c4d5e6f",
  "email": "rider@example.com",
  "displayName": "通勤车",
  "createdAt": "2026-11-06T12:00:00Z"
}
```

### 2.4 修改资料

`PATCH /v1/users/me`（Bearer）

```json
{"displayName":"周末车"}
```

- 只允许改 `displayName`；`email`、密码不在本接口修改。
- `displayName` 传空字符串表示清空。
- 成功 `200`，返回更新后的用户对象。

### 2.5 我的设备

`GET /v1/users/me/devices`（Bearer）

```json
{
  "devices": [
    {
      "id": "BKL-2026-000001",
      "model": "BKL1",
      "state": "CLAIMED",
      "bound": true,
      "label": "通勤车",
      "firmware": "0.1.0",
      "claimedAt": "2026-11-06T12:00:00Z",
      "lastSeenAt": "2026-11-06T12:05:00Z"
    }
  ]
}
```

- 只返回当前车主名下的设备，按 `claimedAt` 倒序。
- 没有设备时返回 `{"devices":[]}`，不是 `null`。

## 3. 设备（已有）

这些接口需要 Bearer token；详细安全语义见 [pairing.md](pairing.md)。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/devices:bind` | 绑定设备，body `{deviceId, claimCode, label?}` |
| GET | `/v1/devices/{deviceID}` | 仅车主可读 |
| DELETE | `/v1/devices/{deviceID}/binding` | 仅车主可解绑 |

设备对象字段与“我的设备”中的元素一致。后端**不返回**车主 ID 与声明码哈希。

## 4. JWT

- 算法：HS256；`alg` 不是 HS256 的 token 一律拒绝。
- Claims：`sub`（用户 UUID）、`email`、`iss`、`iat`、`exp`。
- 默认有效期 24 小时；由服务端 `JWT_TTL` 配置。
- token 只放 `Authorization` 头，不放在 URL/query。
- 服务端日志不记录请求体、密码或 token。

## 5. 当前限制

- 没有 refresh token、logout、改密、邮箱验证、找回密码。
- 注册开放；当前没有邀请码或邮箱验证，生产开放前需要补。
- 登录/注册只做边缘限流（Cloudflare/nginx）；业务级风控属于后续。
- `APP_ENV=dev` 且未配置 `DATABASE_URL` 时，后端仍接受 `X-Dev-User` 开发身份；
  `APP_ENV=prod` 或配置了 Postgres 时只认 JWT。
