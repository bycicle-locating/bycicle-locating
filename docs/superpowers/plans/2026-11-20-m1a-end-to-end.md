# M1a End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一辆真实自行车的 GNSS 点经 EC800M、Mosquitto TLS、Go 后端进入 Postgres，并在 Flutter App 地图上显示最后位置与轨迹。

**Architecture:** 自建 Mosquitto 暴露 8883/TLS（已有私有 CA），设备用 EC800M AT MQTT 上行，后端用 paho 订阅并复用 `internal/protocol` + `ingest`，App 通过现有 JWT API 轮询 `/location` 与 `/track`。M1a 只做上行、RAM ringbuf、OSM 地图；离线补传/低功耗/NFC/BLE 放 M1b。

**Tech Stack:** Go 1.27 + pgx + paho.mqtt.golang；ESP-IDF v5.5.6 C；Flutter 3.44 + Riverpod + dio + flutter_map；Mosquitto 2 + 私有 CA；Postgres 16；Cloudflare Tunnel/nginx。

**Spec:** `docs/superpowers/specs/2026-11-20-m1a-end-to-end-design.md`

## Global Constraints

- 线上后端是 `APP_ENV=prod` + Postgres + JWT；**不得回退 dev 或 `X-Dev-User` 回退**。
- MQTT 必须 TLS + 每设备独立凭据 + ACL；禁止匿名、明文、共用凭据。单条 ≤ 4 KB，单批 ≤ 60 点。
- Broker 证书由私有 CA `Bicycle Locating MQTT CA` 签发；CA 私钥只在服务器（0600），不进仓库；CA 证书可进仓库。
- `mqtt.bycicle-locating.top:8883` 已在 2026-11-20 验证可达；服务器公网 IP 不写入仓库。
- 设备身份/凭据来自 NVS；声明码只在 App/后端使用，不写设备固件；任何密钥/密码不进仓库或日志。
- `seq` 是设备级单调计数器，每点独占；先持久化再使用；排序只信 `seq`。
- 单位：WGS-84、m/s、度、米；App 展示层才换算 km/h。M1a OSM 地图是 WGS-84 的临时例外，不转 GCJ-02。
- 固件 `CONFIG_NEWLIB_NANO_FORMAT=y`，禁止 `%f`；物理量用定点整数。
- App 只能经 `data/` 或 provider 发请求；错误统一 `ApiException`。
- 每个 PR 先改契约文档并同 PR 更新实现；`main` 受保护，走 fork/PR。
- 基线：PR #10 合并后从最新 `origin/main` 开 `feat/m1a-end-to-end`；未合并则基于 `audio-fix`，最后 rebase。

## Review Focus

1. **私有 CA 校验**：后端/模组必须用 `Bicycle Locating MQTT CA` 验证 broker，错误 CA/过期证书/错误主机名必须失败。测试放在 Task 3（错误 CA）和 Task 15（模组 TLS）。
2. **track 语义**：24h 窗口 + limit 500 必须返回**最新** 500 条并按 `seq` 升序，否则 App 折线停在过去。测试放在 Task 4/5/6。
3. **GNSS 解析**：字段顺序、南北纬/东西经符号、km/h→m/s、无定位 `CME ERROR` 不能猜；以真实 `AT+QGPSLOC?` 样本为准。测试放在 Task 12。
4. **seq 重启单调**：设备重启后不能重复使用已发过的 seq，否则后端按 `(device_id, seq)` 去重会吞点。测试放在 Task 16 的真机重启验收。
5. **MQTT 连接/重连/QoS1**：断线重连后重新订阅，重复投递由后端幂等兜底；错误凭据/越权主题必须拒绝。测试放在 Task 3 的集成测试和 Task 8 的 e2e。

## File Structure

**后端（新建/修改）**
- `backend/internal/config/config.go`：增加 MQTT TLS/客户端配置。
- `backend/internal/mqtt/paho.go`：paho 实现 `Bus`；`paho_test.go` 集成测试。
- `backend/internal/store/store.go`：新增 telemetry 查询与 provisioning 接口。
- `backend/internal/store/memory.go`、`postgres_telemetry.go`、`postgres_provision.go`：Memory/Postgres 实现。
- `backend/internal/telemetry/service.go`：位置/轨迹查询服务。
- `backend/internal/provision/provision.go`：声明码生成与设备创建。
- `backend/cmd/device-admin/main.go`：prod 设备 provisioning CLI。
- `backend/internal/api/router.go`：`/location`、`/track`。
- `backend/cmd/server/main.go`：接 PahoBus、telemetry service。
- `backend/deploy/certs/mqtt-ca.crt`：公开 CA 证书。
- `backend/deploy/e2e-mqtt.sh`：模拟设备 e2e。

**固件**
- `firmware/main/dev_config.{c,h}`：NVS 配置加载。
- `firmware/main/modem/at_parser.{c,h}`：AT 行分类纯函数。
- `firmware/main/modem/modem_at.c`：UART/命令/URC 引擎。
- `firmware/main/modem/gnss_parse.{c,h}`：QGPSLOC 解析纯函数。
- `firmware/main/modem/modem_gnss.c`：GNSS 初始化/读取。
- `firmware/main/modem/modem_time.{c,h}`：时间门。
- `firmware/main/modem/modem_mqtt.c`：QMTOPEN/CONN/PUBEX。
- `firmware/main/track/seq_store.{c,h}`：NVS seq 持久化。
- `firmware/main/main.c`：采样/上报任务。
- `firmware/main/certs/mqtt-ca.pem`：设备 CA 证书。
- `scripts/provision-device.py`：生成 NVS 镜像。

**App**
- `app/lib/core/api/api_client.dart`：位置/轨迹 DTO 与请求。
- `app/lib/core/providers.dart`：位置/轨迹 provider。
- `app/lib/features/map/presentation/map_page.dart`：地图。
- `app/pubspec.yaml`：`flutter_map`、`latlong2`。

**文档/CI**
- `docs/http-api.md`、`docs/deployment.md`、`docs/roadmap.md`、`docs/hardware.md`、`firmware/README.md`、`AGENTS.md`。
- `.github/workflows/firmware-host-tests.yml`：新增解析器测试。
- `docs/superpowers/specs/2026-11-20-m1a-end-to-end-design.md`：设计（已批准）。

---

### Task 1: Broker CA 信任与设备凭据

**Files:**
- Create: `backend/deploy/certs/mqtt-ca.crt`
- Create: `firmware/main/certs/mqtt-ca.pem`
- Create: `backend/deploy/mosquitto/acl.example`
- Modify: `docs/deployment.md`（Task 20 收尾，可先不写）

**Interfaces:**
- Consumes: 服务器上的私有 CA 证书（`/opt/.../certs/ca.crt`，具体路径以服务器为准）。
- Produces: 仓库内同一份公开 CA 证书；Mosquitto 设备用户与 ACL。

- [ ] **Step 1: 把 CA 证书复制进仓库**

从服务器复制 CA 证书到两个路径，确认 SHA256 相同：

```bash
sha256sum backend/deploy/certs/mqtt-ca.crt firmware/main/certs/mqtt-ca.pem
```

Expected: 两个 hash 相同。**不要**复制 CA 私钥、设备密码或证书私钥。

- [ ] **Step 2: 验证 TLS 链**

```bash
openssl s_client -connect mqtt.bycicle-locating.top:8883 \
  -servername mqtt.bycicle-locating.top \
  -CAfile backend/deploy/certs/mqtt-ca.crt -verify_return_error </dev/null
```

Expected: `Verify return code: 0 (ok)`，证书 SAN 为 `mqtt.bycicle-locating.top`。

- [ ] **Step 3: 在服务器添加设备用户与 ACL**

在服务器的 Mosquitto 配置目录执行（容器名/路径以实际部署为准）：

```bash
mosquitto_passwd -b /mosquitto/config/passwd BKL-2026-990001 '<device-password>'
```

ACL 至少包含（写入 `backend/deploy/mosquitto/acl.example`，再复制到服务器）：

```text
pattern write v1/device/%u/#
pattern read v1/device/%u/cmd

user backend
topic read v1/device/+/#
topic write v1/device/+/cmd
```

重载/重启 broker 后验证：

```bash
# 匿名必须被拒
mosquitto_pub -h mqtt.bycicle-locating.top -p 8883 \
  --cafile backend/deploy/certs/mqtt-ca.crt -t v1/device/x/telemetry -m '{}'
# 设备用户只能写自己的主题
mosquitto_pub -h mqtt.bycicle-locating.top -p 8883 \
  --cafile backend/deploy/certs/mqtt-ca.crt \
  -u BKL-2026-990001 -P '<device-password>' \
  -t v1/device/BKL-2026-990001/telemetry -m '{}'
```

Expected: 匿名返回 `Connection Refused: not authorised`；设备用户成功；写别人主题被拒。

- [ ] **Step 4: Commit**

```bash
git add backend/deploy/certs/mqtt-ca.crt firmware/main/certs/mqtt-ca.pem backend/deploy/mosquitto/acl.example
git commit -m "chore(mqtt): 加入私有 CA 证书与设备 ACL 示例"
```

---

### Task 2: Backend MQTT 配置字段

**Files:**
- Modify: `backend/internal/config/config.go`
- Test: `backend/internal/config/config_test.go`

**Interfaces:**
- Consumes: 环境变量 `MQTT_URL`、`MQTT_USER`、`MQTT_PASSWORD`。
- Produces: `Config.MQTTCAFile string`、`Config.MQTTClientID string`（env `MQTT_CA_FILE`、`MQTT_CLIENT_ID`，默认 client id `bkl-backend`）。

- [ ] **Step 1: 写失败测试**

```go
func TestLoadMQTTTLSFields(t *testing.T) {
    t.Setenv("MQTT_CA_FILE", "/etc/bkl/mqtt-ca.crt")
    t.Setenv("MQTT_CLIENT_ID", "bkl-backend-test")
    cfg, err := Load()
    if err != nil { t.Fatal(err) }
    if cfg.MQTTCAFile != "/etc/bkl/mqtt-ca.crt" { t.Fatalf("MQTTCAFile=%q", cfg.MQTTCAFile) }
    if cfg.MQTTClientID != "bkl-backend-test" { t.Fatalf("MQTTClientID=%q", cfg.MQTTClientID) }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/config -run TestLoadMQTTTLSFields -v`
Expected: FAIL（字段不存在）。

- [ ] **Step 3: 实现字段**

在 `Config` 增加 `MQTTCAFile string`、`MQTTClientID string`；在 `Load` 读取 `MQTT_CA_FILE`、`MQTT_CLIENT_ID`，`MQTTClientID` 默认 `bkl-backend`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd backend && go test ./internal/config -v`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add backend/internal/config/config.go backend/internal/config/config_test.go
git commit -m "feat(backend): 增加 MQTT TLS 与客户端配置"
```

---

### Task 3: PahoBus

**Files:**
- Create: `backend/internal/mqtt/paho.go`
- Test: `backend/internal/mqtt/paho_test.go`
- Modify: `backend/go.mod`、`backend/go.sum`

**Interfaces:**
- Consumes: `PahoConfig{URL, ClientID, Username, Password, CAFile string}`。
- Produces: `NewPahoBus(cfg PahoConfig, log *slog.Logger) (*PahoBus, error)`；`*PahoBus` 实现现有 `Bus`。

- [ ] **Step 1: 写失败测试**

```go
func TestNewPahoBusRejectsMissingURL(t *testing.T) {
    if _, err := NewPahoBus(PahoConfig{}, slog.Default()); err == nil {
        t.Fatal("empty URL must fail")
    }
}

func TestNewPahoBusRejectsMissingCA(t *testing.T) {
    _, err := NewPahoBus(PahoConfig{URL: "mqtts://example:8883", CAFile: "does-not-exist"}, slog.Default())
    if err == nil { t.Fatal("missing CA must fail") }
}
```

集成测试（`TEST_MQTT_URL` 未设置时跳过；另设 `TEST_MQTT_BAD_CA` 指向错误 CA 时，连接必须失败）：

```go
func TestPahoBusPublishSubscribe(t *testing.T) {
    url := os.Getenv("TEST_MQTT_URL")
    if url == "" { t.Skip("set TEST_MQTT_URL") }
    bus, err := NewPahoBus(PahoConfig{
        URL: url, ClientID: "bkl-test", Username: os.Getenv("TEST_MQTT_USER"),
        Password: os.Getenv("TEST_MQTT_PASS"), CAFile: os.Getenv("TEST_MQTT_CA"),
    }, slog.Default())
    if err != nil { t.Fatal(err) }
    defer bus.Close()
    got := make(chan string, 1)
    if err := bus.Subscribe(context.Background(), "v1/device/test/#", func(_ context.Context, m Message) error {
        got <- string(m.Payload); return nil
    }); err != nil { t.Fatal(err) }
    if err := bus.Publish(context.Background(), "v1/device/test/telemetry", []byte("ok"), 1, false); err != nil { t.Fatal(err) }
    select { case <-got: case <-time.After(3*time.Second): t.Fatal("no message") }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/mqtt -v`
Expected: FAIL（`NewPahoBus` undefined）。

- [ ] **Step 3: 实现 PahoBus**

添加依赖 `go get github.com/eclipse/paho.mqtt.golang`。`NewPahoBus` 解析 URL，`mqtts` 时加载 CA 并设置 `tls.Config{RootCAs, ServerName}`；设置 `CleanSession=false`、自动重连、重连间隔上限 5 min。`Subscribe` 用互斥锁串行调用 handler；`Publish` 用 `token.WaitTimeout(ctx)`；`Close` `Disconnect(250)`。TLS 配置错误必须返回 error，不能降级为明文。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd backend && go test ./internal/mqtt -v`
Expected: 单元测试 PASS；设置 `TEST_MQTT_*` 后集成测试 PASS；设置 `TEST_MQTT_BAD_CA` 后错误 CA 必须失败。

- [ ] **Step 5: Commit**

```bash
git add backend/go.mod backend/go.sum backend/internal/mqtt/paho.go backend/internal/mqtt/paho_test.go
git commit -m "feat(backend): 接入 paho MQTT 客户端"
```

---

### Task 4: Store 位置/轨迹查询

**Files:**
- Modify: `backend/internal/store/store.go`
- Modify: `backend/internal/store/memory.go`
- Create: `backend/internal/store/postgres_telemetry.go`
- Test: `backend/internal/store/memory_test.go`、`backend/internal/store/postgres_test.go`

**Interfaces:**
- Produces:
```go
LatestTelemetry(ctx context.Context, deviceID string) (TelemetryPoint, error)
TelemetrySince(ctx context.Context, deviceID string, since time.Time, limit int) ([]TelemetryPoint, error)
```
- 语义：`Latest` 按 `seq` 最大；`TelemetrySince` 过滤 `ts >= since`，取 `seq` 最大的 `limit` 条，再按 `seq` 升序返回；无记录返回 `ErrNotFound`（Latest）或空 slice（Since）。

- [ ] **Step 1: 写失败测试**

```go
func TestMemoryTelemetrySinceReturnsNewestLimitAscending(t *testing.T) {
    m := NewMemory()
    for i := uint32(1); i <= 10; i++ {
        _, _ = m.InsertTelemetry(context.Background(), []TelemetryPoint{{
            DeviceID: "d1", Seq: i, Time: time.Unix(int64(i), 0).UTC(), Lat: float64(i), Lon: 0,
        }})
    }
    got, err := m.TelemetrySince(context.Background(), "d1", time.Unix(1, 0).UTC(), 3)
    if err != nil { t.Fatal(err) }
    if len(got) != 3 || got[0].Seq != 8 || got[2].Seq != 10 {
        t.Fatalf("got seqs %v", []uint32{got[0].Seq, got[1].Seq, got[2].Seq})
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/store -run Telemetry -v`
Expected: FAIL（方法不存在）。

- [ ] **Step 3: 实现 Memory 与 Postgres**

Memory：在 `m.points[deviceID]` 上过滤/排序/截取。Postgres：`postgres_telemetry.go` 增加 `scanTelemetryPoint`；`LatestTelemetry` 用 `ORDER BY seq DESC LIMIT 1`；`TelemetrySince` 用 `ORDER BY seq DESC LIMIT $3`，Go 侧反转。SQL 必须参数化。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd backend && go test ./internal/store -v`
Expected: Memory PASS；设置 `TEST_DATABASE_URL` 后 Postgres 集成 PASS。

- [ ] **Step 5: Commit**

```bash
git add backend/internal/store
git commit -m "feat(backend): 增加最新位置与轨迹查询"
```

---

### Task 5: Telemetry 服务

**Files:**
- Create: `backend/internal/telemetry/service.go`
- Test: `backend/internal/telemetry/service_test.go`

**Interfaces:**
```go
type Service struct { /* store */ }
func New(st store.Store) *Service
func (s *Service) Latest(ctx context.Context, deviceID string) (store.TelemetryPoint, error)
func (s *Service) Track(ctx context.Context, deviceID string, since time.Time, limit int) ([]store.TelemetryPoint, error)
```
`Track` 将 `limit <= 0` 设为 500，>500 夹到 500；`since` 为零时设为 24h 前。

- [ ] **Step 1: 写失败测试**

```go
func TestTrackClampsLimit(t *testing.T) {
    m := store.NewMemory()
    // insert 2 points
    s := New(m)
    got, err := s.Track(context.Background(), "d1", time.Now().Add(-time.Hour), 9999)
    if err != nil { t.Fatal(err) }
    if len(got) != 2 { t.Fatalf("len=%d", len(got)) }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/telemetry -v`
Expected: FAIL（包不存在）。

- [ ] **Step 3: 实现服务**

按接口实现；不做权限判断（API 层做车主校验）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd backend && go test ./internal/telemetry -v`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add backend/internal/telemetry
git commit -m "feat(backend): 增加 telemetry 查询服务"
```

---

### Task 6: HTTP location/track 接口

**Files:**
- Modify: `backend/internal/api/router.go`
- Test: `backend/internal/api/router_test.go`

**Interfaces:**
- `Server.telemetry *telemetry.Service`；`New(devices *device.Service, users *user.Service, telemetry *telemetry.Service, tokens *auth.Tokens, authn Authenticator, log *slog.Logger) *Server`。
- 路由：
```go
mux.HandleFunc("GET /v1/devices/{deviceID}/location", s.handleLocation)
mux.HandleFunc("GET /v1/devices/{deviceID}/track", s.handleTrack)
```
- DTO：
```go
type locationDTO struct {
    DeviceID string `json:"deviceId"`
    Seq uint32 `json:"seq"`
    TS time.Time `json:"ts"`
    Lat float64 `json:"lat"`
    Lon float64 `json:"lon"`
    SpeedMPS float64 `json:"speedMps"`
    CourseDeg float64 `json:"courseDeg"`
    AltM *float64 `json:"altM,omitempty"`
    HDOP *float64 `json:"hdop,omitempty"`
    Fix int `json:"fix"`
}
type trackResponse struct { Points []locationDTO `json:"points"` }
```
- 权限：先 `s.devices.Get`；设备不存在或非车主统一 403；有设备但无点：location 404，track 200 空数组。
- `since` 缺省 24h，非法 RFC3339 → 400；`limit` 1..500。

- [ ] **Step 1: 写失败测试**

```go
func TestLocationNoDataNotFound(t *testing.T) {
    // setup server with memory store, bound device, no telemetry
    // request with owner JWT
    // expect 404
}
func TestLocationNonOwnerForbidden(t *testing.T) { /* expect 403 */ }
func TestTrackReturnsNewestLimitAscending(t *testing.T) { /* insert 10, expect seq 8,9,10 */ }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/api -run 'Location|Track' -v`
Expected: FAIL（路由/字段不存在）。

- [ ] **Step 3: 实现 handlers 与 DTO**

更新 `New` 调用点（`cmd/server/main.go`、测试）。`handleLocation`/`handleTrack` 按接口实现；错误映射遵循现有 `writeError`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd backend && go test ./internal/api -v`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add backend/internal/api/router.go backend/internal/api/router_test.go
git commit -m "feat(api): 增加设备位置与轨迹接口"
```

---

### Task 7: Prod 设备 provisioning

**Files:**
- Modify: `backend/internal/store/store.go`（`ErrDeviceExists`、`DeviceProvisioner`）
- Modify: `backend/internal/store/memory.go`
- Create: `backend/internal/store/postgres_provision.go`
- Create: `backend/internal/provision/provision.go`
- Test: `backend/internal/provision/provision_test.go`
- Create: `backend/cmd/device-admin/main.go`
- Modify: `backend/Dockerfile`

**Interfaces:**
```go
var ErrDeviceExists = errors.New("store: 设备已存在")

type DeviceProvisioner interface {
    CreateDevice(ctx context.Context, d Device, claimCodeHash string) error
}

func ClaimCode() (string, error) // 16 字符 A-Z2-7
func CreateDevice(ctx context.Context, p store.DeviceProvisioner, pepper, id, model string) (claimCode string, err error)
```
CLI：`bkl-device-admin -id BKL-2026-990001 -model BKL1`，从 env 读 `DATABASE_URL`、`CLAIM_PEPPER`；stdout 只打印一次 `deviceId=... claimCode=...`。

- [ ] **Step 1: 写失败测试**

```go
func TestClaimCodeFormat(t *testing.T) {
    code, err := ClaimCode()
    if err != nil { t.Fatal(err) }
    if !regexp.MustCompile(`^[A-Z2-7]{16}$`).MatchString(code) { t.Fatalf("bad code %q", code) }
}
func TestCreateDeviceDuplicate(t *testing.T) {
    m := store.NewMemory()
    if _, err := CreateDevice(context.Background(), m, "pepper-0123456789", "BKL-2026-990001", "BKL1"); err != nil { t.Fatal(err) }
    if _, err := CreateDevice(context.Background(), m, "pepper-0123456789", "BKL-2026-990001", "BKL1"); !errors.Is(err, store.ErrDeviceExists) { t.Fatalf("err=%v", err) }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd backend && go test ./internal/provision -v`
Expected: FAIL。

- [ ] **Step 3: 实现 provisioning 与 CLI**

`ClaimCode` 用 `crypto/rand` 10 字节 + `base32.StdEncoding.WithPadding(NoPadding)`（输出即 A-Z2-7）。`CreateDevice` 用 `device.NewHMACHasher(pepper)` 哈希；`CreateDevice` 写入 `CLAIMABLE` 状态。Postgres 用 `INSERT ... RETURNING id`，唯一冲突映射 `ErrDeviceExists`。Dockerfile 增加：

```dockerfile
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/bkl-device-admin ./cmd/device-admin
COPY --from=build /out/bkl-device-admin /usr/local/bin/bkl-device-admin
```

- [ ] **Step 4: 运行测试与构建**

Run: `cd backend && go test ./internal/provision ./internal/store -v && go build ./cmd/device-admin`
Expected: PASS；二进制生成。

- [ ] **Step 5: Commit**

```bash
git add backend/internal/store backend/internal/provision backend/cmd/device-admin backend/Dockerfile
git commit -m "feat(backend): 增加 prod 设备 provisioning CLI"
```

---

### Task 8: 后端接线、Compose 与模拟设备 e2e

**Files:**
- Modify: `backend/cmd/server/main.go`
- Modify: `backend/docker-compose.yml`
- Modify: `backend/.env.example`
- Create: `backend/deploy/e2e-mqtt.sh`
- Test: `backend/internal/api/router_test.go`（New 调用点）

**Interfaces:**
- `openBus(cfg config.Config, log *slog.Logger) (mqtt.Bus, error)`：显式配置了 `MQTT_URL`（非空且不是 `tcp://127.0.0.1:1883`）用 `NewPahoBus`；纯本地 dev 且 URL 为默认值时用 `LogBus`；`APP_ENV=prod` 且 URL 为空/默认值时返回错误。prod 必须是 `mqtts://...:8883`。
- `main` 构造 `telemetry.New(st)` 并传给 `api.New`。
- Compose 后端增加 `MQTT_CA_FILE=/etc/bkl/mqtt-ca.crt`、`MQTT_CLIENT_ID=bkl-backend`，挂载 CA，`extra_hosts` 把 `mqtt.bycicle-locating.top` 指向 `host-gateway`。

- [ ] **Step 1: 写失败测试**

`TestServerNewRequiresTelemetry`：编译期/构造测试，确保 `api.New` 签名变化后所有调用点更新。

- [ ] **Step 2: 实现接线**

`openBus` 与 `api.New` 调用；`MQTT_URL=mqtts://mqtt.bycicle-locating.top:8883` 时用 Paho。`APP_ENV=prod` 且无 `MQTT_URL` 拒绝启动。

- [ ] **Step 3: 写 e2e 脚本**

`backend/deploy/e2e-mqtt.sh`：
- 用 `mosquitto_pub` + `--cafile` + 设备用户名/密码发布一条合法 telemetry JSON（`jq` 生成或 heredoc）。
- 用 `psql`/`docker compose exec postgres` 断言 `telemetry_points` 有该 `(device_id, seq)` 行。
- 用 API JWT 调 `/track` 断言返回该点（需要测试账号 token；可从 `user-smoke.sh` 复用注册/登录逻辑）。

- [ ] **Step 4: 运行验证**

Run: `cd backend && go test ./...`
Expected: PASS。
Run: `MQTT_*` 环境变量齐全后 `bash deploy/e2e-mqtt.sh`
Expected: 脚本输出 `OK`，DB 与 API 都能看到点。

- [ ] **Step 5: Commit**

```bash
git add backend/cmd/server backend/docker-compose.yml backend/.env.example backend/deploy/e2e-mqtt.sh
git commit -m "feat(backend): 接入 MQTT 总线并补模拟设备 e2e"
```

---

### Task 9: 固件 NVS 配置与 provisioning 脚本

**Files:**
- Create: `firmware/main/dev_config.h`、`firmware/main/dev_config.c`
- Modify: `firmware/main/CMakeLists.txt`
- Create: `scripts/provision-device.py`
- Create: `scripts/README.md`
- Test: `scripts/test_provision.py`

**Interfaces:**
```c
typedef struct {
    char device_id[32];
    char mqtt_host[64];
    uint16_t mqtt_port;
    char mqtt_user[32];
    char mqtt_pass[64];
} bkl_dev_config_t;

esp_err_t bkl_dev_config_load(bkl_dev_config_t *out);
```
NVS namespace `bkl`，key：`device_id`、`mqtt_host`、`mqtt_port`（**u16**，CSV type 用 `u16`）、`mqtt_user`、`mqtt_pass`。

- [ ] **Step 1: 写脚本测试**

`scripts/test_provision.py` 调 `--csv-only` 生成 CSV，断言包含 5 个 key，且 stdout 不包含密码：

```python
assert "mqtt_pass" in csv_text
assert password not in captured_stdout
```

- [ ] **Step 2: 实现脚本**

`scripts/provision-device.py` 参数：`--device-id`、`--mqtt-host`、`--mqtt-port`、`--mqtt-pass`（必需；可由 `--generate-pass` 生成）、`--out nvs.bin`。生成 CSV，调用 `nvs_partition_gen.py generate <csv> <bin> 0x5000`（若可用），打印 `esptool write_flash 0x9000 <bin>`；CSV 含密码，文件权限 0600，不打印密码。

- [ ] **Step 3: 实现 `bkl_dev_config_load`**

从 NVS 读取；缺失/超长返回 `ESP_ERR_NOT_FOUND`/`ESP_ERR_INVALID_SIZE`。`main.c` 用该结构替代 `load_device_id`。

- [ ] **Step 4: 运行测试**

Run: `cd scripts && python -m unittest test_provision.py -v`
Expected: PASS。
Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。

- [ ] **Step 5: Commit**

```bash
git add firmware/main/dev_config.* firmware/main/CMakeLists.txt scripts/provision-device.py scripts/README.md scripts/test_provision.py
git commit -m "feat(fw): 增加 NVS 设备配置与 provisioning 脚本"
```

---

### Task 10: AT 行分类纯函数

**Files:**
- Create: `firmware/main/modem/at_parser.h`、`firmware/main/modem/at_parser.c`
- Test: `firmware/test/host/test_at_parser.c`
- Modify: `firmware/main/CMakeLists.txt`、`.github/workflows/firmware-host-tests.yml`

**Interfaces:**
```c
typedef enum {
    BKL_AT_LINE_OTHER = 0,
    BKL_AT_LINE_OK,
    BKL_AT_LINE_ERROR,
    BKL_AT_LINE_URC,
} bkl_at_line_kind_t;

bkl_at_line_kind_t bkl_at_classify_line(const char *line, const char *expect_prefix);
```

- [ ] **Step 1: 写失败测试**

```c
TEST_ASSERT(bkl_at_classify_line("OK", "+QMTOPEN:") == BKL_AT_LINE_OK);
TEST_ASSERT(bkl_at_classify_line("ERROR", "+QMTOPEN:") == BKL_AT_LINE_ERROR);
TEST_ASSERT(bkl_at_classify_line("+CME ERROR: 516", "+QGPSLOC:") == BKL_AT_LINE_ERROR);
TEST_ASSERT(bkl_at_classify_line("+QMTOPEN: 0,0", "+QMTOPEN:") == BKL_AT_LINE_URC);
TEST_ASSERT(bkl_at_classify_line("+QMTRECV: 0,1,\"v1/device/x/cmd\",42", "+QMTOPEN:") == BKL_AT_LINE_URC);
TEST_ASSERT(bkl_at_classify_line("AT+QMTOPEN=0,\"h\",8883", "+QMTOPEN:") == BKL_AT_LINE_OTHER);
```

- [ ] **Step 2: 运行确认失败**

Run: `cd firmware && gcc -std=c11 -Wall -Wextra -Werror -I main -I main/modem test/host/test_at_parser.c main/modem/at_parser.c -o test_at_parser && ./test_at_parser`
Expected: 编译失败（函数不存在）。

- [ ] **Step 3: 实现分类器**

规则：trim 后 `OK`→OK、`ERROR`/`+CME ERROR`→ERROR；以 `+` 开头且不等于 expect 的 URC 前缀→URC；以 expect 开头→URC（等待匹配）；其余→OTHER（含 echo）。

- [ ] **Step 4: 运行确认通过**

Run: 同上
Expected: 输出「AT parser tests passed」。

- [ ] **Step 5: Commit**

```bash
git add firmware/main/modem/at_parser.* firmware/test/host/test_at_parser.c firmware/main/CMakeLists.txt .github/workflows/firmware-host-tests.yml
git commit -m "feat(fw): 增加 AT 行分类器与主机单测"
```

---

### Task 11: AT UART 引擎

**Files:**
- Modify: `firmware/main/modem/modem_at.c`

**Interfaces:**
- 保持 `bkl_at_init`、`bkl_at_cmd`、`bkl_at_register_urc`、`bkl_at_ready` 不变。

- [ ] **Step 1: 实现 UART 与读任务**

`uart_driver_install` UART1，115200 8N1，GPIO17 TX / GPIO16 RX；读任务按行切分，调用 `bkl_at_classify_line`；匹配等待中的命令则释放信号量并复制行；URC 分发给注册的 handler。命令写用互斥锁，超时后清缓冲/重试一次。

- [ ] **Step 2: 编译**

Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。

- [ ] **Step 3: 真机验证**

烧录后日志出现 `AT ready`；`bkl_at_cmd("ATI", "+", ...)` 返回模组型号（可在启动日志打一次 `ATI`）。失败时记录原始行。

- [ ] **Step 4: Commit**

```bash
git add firmware/main/modem/modem_at.c
git commit -m "feat(fw): 实现 EC800M AT UART 引擎"
```

---

### Task 12: GNSS QGPSLOC 解析器

**Files:**
- Create: `firmware/main/modem/gnss_parse.h`、`firmware/main/modem/gnss_parse.c`
- Test: `firmware/test/host/test_gnss_parse.c`
- Create: `firmware/test/host/fixtures/qgpsloc_outdoor.txt`

**Interfaces:**
```c
esp_err_t bkl_gnss_parse_qgpsloc(const char *response, bkl_point_t *out, uint8_t *satellites);
```
返回 `ESP_OK` 有效；`ESP_ERR_NOT_FOUND` 无定位（`+CME ERROR: 516`）；`ESP_ERR_INVALID_ARG` 格式错误。

- [ ] **Step 1: Gate 1 抓真实样本**

用外接 USB-TTL 或临时 AT 控制台，室外执行 `AT+QGPS=1`，等待定位，抓 `AT+QGPSLOC?` 原始响应；再抓室内 `+CME ERROR: 516`。把原始行与期望值填入 fixture 头部：

```text
# raw: +QGPSLOC: <实际字段...>
# expect: lat=<...> lon=<...> speed_mm_s=<...> course_cdeg=<...> alt_cm=<...> fix=<...>
# nofix: +CME ERROR: 516
```

**不得按常见 Quectel 顺序猜字段。**

- [ ] **Step 2: 写失败测试**

测试读取 fixture，断言 `out->lat/lon/speed_mm_s/course_cdeg/alt_cm/fix` 与头部期望值一致；南纬/西经为负；`+CME ERROR: 516` 返回 `ESP_ERR_NOT_FOUND`；空行返回 `ESP_ERR_INVALID_ARG`。

- [ ] **Step 3: 实现解析器**

按实际字段顺序解析；速度 `km/h → mm/s` 用整数 `kmh * 1000000 / 3600`；UTC 转 epoch；坐标转 1e-7 度；航向转 0.01 度；海拔转 cm。

- [ ] **Step 4: 运行测试**

Run: `cd firmware && gcc -std=c11 -Wall -Wextra -Werror -I main -I main/modem test/host/test_gnss_parse.c main/modem/gnss_parse.c main/app_types.c -o test_gnss_parse && ./test_gnss_parse`
Expected: 输出「GNSS parser tests passed」。

- [ ] **Step 5: Commit**

```bash
git add firmware/main/modem/gnss_parse.* firmware/test/host/test_gnss_parse.c firmware/test/host/fixtures/qgpsloc_outdoor.txt firmware/main/CMakeLists.txt .github/workflows/firmware-host-tests.yml
git commit -m "feat(fw): 增加 QGPSLOC 解析器与真实样本单测"
```

---

### Task 13: GNSS 初始化/读取

**Files:**
- Modify: `firmware/main/modem/modem_gnss.c`

**Interfaces:**
- 保持 `bkl_gnss_init`、`bkl_gnss_power`、`bkl_gnss_read` 不变。

- [ ] **Step 1: 实现 `bkl_gnss_init`**

`bkl_at_cmd("AT+QGPS=1", "OK", ...)`；失败返回错误，不阻塞启动。

- [ ] **Step 2: 实现 `bkl_gnss_read`**

`bkl_at_cmd("AT+QGPSLOC?", "+QGPSLOC:", line, ...)`；成功调用 `bkl_gnss_parse_qgpsloc`；`+CME ERROR: 516` 返回 `ESP_ERR_NOT_FOUND` 并置 `valid=false`。

- [ ] **Step 3: 编译与真机验证**

Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。
室外烧录，日志显示 `GNSS valid lat=... lon=...`；室内显示 `no fix`，不崩溃。

- [ ] **Step 4: Commit**

```bash
git add firmware/main/modem/modem_gnss.c
git commit -m "feat(fw): 接通 EC800M GNSS 读取"
```

---

### Task 14: TLS 前时间门

**Files:**
- Create: `firmware/main/modem/modem_time.h`、`firmware/main/modem/modem_time.c`
- Modify: `firmware/main/CMakeLists.txt`、`firmware/main/main.c`

**Interfaces:**
```c
esp_err_t bkl_time_sync(uint32_t timeout_ms);
int64_t bkl_time_now_s(void); // 无效时返回 0
```

- [ ] **Step 1: 实现网络时间优先**

`AT+QLTS=2` 或 `AT+CCLK?` 解析网络时间；有效则 `bkl_time_now_s()` 返回 epoch。无效时等 GNSS 首次有效 UTC，再 `AT+CCLK="yy/MM/dd,hh:mm:ss±zz"`。具体 AT 指令/章节记录在代码注释。

- [ ] **Step 2: 编译与真机验证**

Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。日志在 MQTT 连接前出现 `time valid <epoch>`；若时间无效，禁止进入 MQTT。

- [ ] **Step 3: Commit**

```bash
git add firmware/main/modem/modem_time.* firmware/main/CMakeLists.txt firmware/main/main.c
git commit -m "feat(fw): TLS 前增加时间门"
```

---

### Task 15: MQTT AT 连接与发布

**Files:**
- Modify: `firmware/main/modem/modem_mqtt.c`
- Modify: `firmware/main/Kconfig.projbuild`（增加 `BKL_MQTT_CA_PATH`，默认 `/mqtt-ca.pem`）

**Interfaces:**
- 保持 `bkl_mqtt_connect`、`bkl_mqtt_publish`、`bkl_mqtt_connected`、`bkl_mqtt_disconnect_graceful` 不变。

- [ ] **Step 1: 上传 CA 并实现连接**

先通过 AT 命令把 `firmware/main/certs/mqtt-ca.pem` 写入模组 UFS（`AT+QFUPL="<CONFIG_BKL_MQTT_CA_PATH>",<size>,<timeout>`，随后发送文件内容；用 `AT+QFLST` 确认文件存在）。然后按序列连接：`AT+QMTCFG="version",0,4`；`AT+QMTCFG="ssl",0,1,0`；`AT+QSSLCFG="sslversion",0,4`；`AT+QSSLCFG="seclevel",0,1`；`AT+QSSLCFG="cacert",0,"<CONFIG_BKL_MQTT_CA_PATH>"`；`AT+QMTOPEN=0,"<host>",8883` 等 `+QMTOPEN: 0,0`；`AT+QMTCONN=0,"<clientId>","<user>","<pass>"` 等 `+QMTCONN: 0,0,0`。失败返回 `esp_err_t`，记录 AT 行。

- [ ] **Step 2: 实现发布**

`AT+QMTPUBEX=0,<msgId>,1,0,"<topic>",<len>` 等 `>`；发送 payload；等 `OK` 与 `+QMTPUB: 0,<msgId>,0`。一次只允许一个在途发布；msgId 递增。

- [ ] **Step 3: 编译与真机验证**

Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。
烧录后设备连接私有 CA broker；后端日志出现 ingest；错误 CA/错误密码必须失败。

- [ ] **Step 4: Commit**

```bash
git add firmware/main/modem/modem_mqtt.c firmware/main/Kconfig.projbuild
git commit -m "feat(fw): 实现 EC800M MQTT TLS 连接与发布"
```

---

### Task 16: seq 持久化与采样/上报任务

**Files:**
- Create: `firmware/main/track/seq_store.h`、`firmware/main/track/seq_store.c`
- Modify: `firmware/main/main.c`、`firmware/main/CMakeLists.txt`

**Interfaces:**
```c
esp_err_t bkl_seq_init(void);
esp_err_t bkl_seq_next(uint32_t *out); // 先持久化再返回
```

- [ ] **Step 1: 实现 seq_store**

NVS key `seq`；`bkl_seq_init` 读取，缺失从 1 开始；`bkl_seq_next` 递增、`nvs_set_u32` + `nvs_commit` 成功后才返回新值。写失败返回错误，调用方不得使用该 seq。

- [ ] **Step 2: 接采样/上报任务**

`main.c`：加载 `bkl_dev_config`；初始化 AT/时间门/MQTT/GNSS；RAM ringbuf 扩到 64 条；`sample_task` 每 10 s 读 GNSS，有效则 `bkl_seq_next` + `bkl_ringbuf_push`；`upload_task` 每 1 s 检查，`bkl_uploader_step` 用 `publish_via_mqtt`（`bkl_mqtt_publish(..., qos=1)`）。连接成功后发布一次 `status{online:true}`。**保留现有 `bkl_audio_init()` 与音频自检开关，不改音频行为。**

- [ ] **Step 3: 编译与真机验证**

Run: `cd firmware && idf.py -B ../fwbuild build`
Expected: 编译通过。
烧录后：设备发布 status/telemetry；后端 DB 有点；重启设备后新点 seq 继续递增，不被后端去重吞掉。

- [ ] **Step 4: Commit**

```bash
git add firmware/main/main.c firmware/main/track/seq_store.* firmware/main/CMakeLists.txt
git commit -m "feat(fw): 接 seq 持久化与采样上报任务"
```

---

### Task 17: App API DTO 与请求

**Files:**
- Modify: `app/pubspec.yaml`、`app/pubspec.lock`
- Modify: `app/lib/core/api/api_client.dart`
- Test: `app/test/api_client_test.dart`

**Interfaces:**
```dart
class DeviceLocation {
  const DeviceLocation({required this.seq, required this.ts, required this.lat, required this.lon,
    required this.speedMps, required this.courseDeg, this.altM, this.hdop, required this.fix});
  factory DeviceLocation.fromJson(Map<String, dynamic> json);
}
class DeviceTrackPoint { /* seq, ts, lat, lon, speedMps, courseDeg */ }

Future<DeviceLocation?> fetchLocation(String deviceId); // 404 -> null
Future<List<DeviceTrackPoint>> fetchTrack(String deviceId, {DateTime? since, int limit = 500});
```

- [ ] **Step 1: 加依赖**

`cd app && flutter pub add flutter_map latlong2`；确认 `pubspec.lock` 更新。版本以 Flutter 3.44 兼容的最新稳定版为准，不手写不存在的版本号。

- [ ] **Step 2: 写失败测试**

用 `Dio` + fake `HttpClientAdapter` 返回固定 JSON，断言解析字段与 404→null、403→`ApiException`。

- [ ] **Step 3: 实现 DTO/方法**

在 `ApiClient` 增加两个方法；错误统一 `_toApiException`；`since` 用 `toUtc().toIso8601String()`；`limit` 夹 1..500。

- [ ] **Step 4: 运行测试**

Run: `cd app && flutter test test/api_client_test.dart`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/core/api/api_client.dart app/test/api_client_test.dart
git commit -m "feat(app): 增加位置与轨迹 API"
```

---

### Task 18: App 位置/轨迹 Provider

**Files:**
- Modify: `app/lib/core/providers.dart`
- Test: `app/test/location_providers_test.dart`

**Interfaces:**
```dart
final deviceLocationProvider = FutureProvider.autoDispose.family<DeviceLocation?, String>(
  (ref, deviceId) => ref.watch(apiClientProvider).fetchLocation(deviceId),
);
final deviceTrackProvider = FutureProvider.autoDispose.family<List<DeviceTrackPoint>, String>(
  (ref, deviceId) => ref.watch(apiClientProvider).fetchTrack(deviceId),
);
```

- [ ] **Step 1: 写失败测试**

用 `ProviderContainer` + 覆盖 `apiClientProvider` 的 fake `ApiClient`，断言两个 provider 返回值。

- [ ] **Step 2: 实现 provider**

按接口添加；不要在地图 widget 里直接发请求。

- [ ] **Step 3: 运行测试**

Run: `cd app && flutter test test/location_providers_test.dart`
Expected: PASS。

- [ ] **Step 4: Commit**

```bash
git add app/lib/core/providers.dart app/test/location_providers_test.dart
git commit -m "feat(app): 增加位置与轨迹 provider"
```

---

### Task 19: App 地图页

**Files:**
- Modify: `app/lib/features/map/presentation/map_page.dart`
- Test: `app/test/map_page_test.dart`

**Interfaces:**
- 使用 `FlutterMap` + `TileLayer`（`https://tile.openstreetmap.org/{z}/{x}/{y}.png`，`userAgentPackageName: 'top.byciclelocating.app'`）+ `MarkerLayer` + `PolylineLayer`。
- 读取 `selectedDeviceProvider`、`deviceLocationProvider`、`deviceTrackProvider`；每 10 s `ref.invalidate` 两个 provider；dispose 取消 timer。

- [ ] **Step 1: 写失败测试**

覆盖 `devicesProvider`/`selectedDeviceProvider`/两个位置 provider：
- 无位置时显示「暂无位置」；
- 有位置时存在 `MarkerLayer` 与 `PolylineLayer`；
- 加载/错误状态可渲染。
测试注入 fake `TileProvider`，避免真实网络。

- [ ] **Step 2: 实现地图布局**

在现有面板卡片中放一个固定高度地图（例如 320 px），保留设备管理入口；地图上叠加最后更新时间/速度（km/h 展示层换算）。无设备时保留现有空态。

- [ ] **Step 3: 运行测试**

Run: `cd app && flutter analyze && flutter test test/map_page_test.dart`
Expected: 0 issue；PASS。

- [ ] **Step 4: Commit**

```bash
git add app/lib/features/map/presentation/map_page.dart app/test/map_page_test.dart
git commit -m "feat(app): 地图显示最后位置与轨迹"
```

---

### Task 20: 文档、CI 与端到端验收

**Files:**
- Modify: `README.md`、`docs/http-api.md`、`docs/protocol.md`、`docs/deployment.md`、`docs/roadmap.md`、`docs/hardware.md`、`firmware/README.md`、`AGENTS.md`
- Modify: `.github/workflows/firmware-host-tests.yml`
- Create: `docs/runbooks/m1a-e2e.md`（或等价）

- [ ] **Step 1: 更新契约文档**

`README.md` 修正“M0 空实现/缺 Android/ESP-IDF 未验证”等过期状态；`http-api.md` 增加 `/location`、`/track` 的请求/响应/错误；`protocol.md` 补充 broker TLS/ACL/设备凭据与 seq 持久化；`deployment.md` 改为 prod+Postgres+JWT 真实状态、私有 CA、8883、broker 账号/ACL、预检命令；`roadmap.md` 修正 M0/M1 勾选并拆 M1a/M1b；`hardware.md` 记录 flash 16MB 与 CA/AT 抓样本步骤；`firmware/README.md` 更新模块状态。

- [ ] **Step 2: 更新 CI**

`firmware-host-tests.yml` 增加 `test_at_parser`、`test_gnss_parse` 编译/运行；确认 `test_core`/`test_audio` 仍过。Go/Flutter CI 已覆盖新测试。

- [ ] **Step 3: 写 e2e 验收 runbook**

`docs/runbooks/m1a-e2e.md` 列出：服务器 preflight、证书/CA、账号/ACL、`device-admin` 创建 `BKL-2026-990001`、NVS provisioning、烧录、室外开机、App 绑定、地图验收、故障排查、回滚。

- [ ] **Step 4: 全量验证**

```bash
cd backend && go test ./...
cd app && flutter analyze && flutter test
cd firmware && idf.py -B ../fwbuild build
cd firmware && gcc -std=c11 -Wall -Wextra -Werror -I main -I main/modem \
  test/host/test_at_parser.c main/modem/at_parser.c -o test_at_parser && ./test_at_parser
cd firmware && gcc -std=c11 -Wall -Wextra -Werror -I main -I main/modem \
  test/host/test_gnss_parse.c main/modem/gnss_parse.c main/app_types.c -o test_gnss_parse && ./test_gnss_parse
```

Expected: 全绿；真车室外 5 分钟内在 App 看到至少一个点；重启后端数据仍在。

- [ ] **Step 5: Commit**

```bash
git add docs .github/workflows/firmware-host-tests.yml firmware/README.md AGENTS.md
git commit -m "docs: 完成 M1a 端到端验收与部署说明"
```

---

## Self-Review Notes

- Spec coverage: 自建 broker/TLS/ACL（Task 1/3/15）、prod provisioning（Task 7）、后端 MQTT/API（Task 3-8）、固件 AT/MQTT/GNSS/seq（Task 9-16）、App 地图（Task 17-19）、文档/CI/e2e（Task 20）。
- 真实 AT 样本是 Task 12 的前置 Gate；没有样本不写解析器。
- 私有 CA 是 Task 1 的前置；后端/模组都不能跳过 CA 校验。
- 已知未覆盖：LittleFS 离线补传、睡眠、NFC/BLE、iOS、生产地图 GCJ-02；均属 M1b/M2。
