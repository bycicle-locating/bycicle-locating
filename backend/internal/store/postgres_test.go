package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"
)

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func newTestUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// TestPostgresStore 需要已执行 deploy/migrate 的数据库；未设置 TEST_DATABASE_URL 时跳过。
func TestPostgresStore(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("未设置 TEST_DATABASE_URL")
	}
	ctx := context.Background()
	pg, err := NewPostgres(ctx, dsn)
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	defer pg.Close()
	if err := pg.CheckSchema(ctx); err != nil {
		t.Skipf("数据库未迁移：%v", err)
	}

	email := "pg-" + randomHex(8) + "@example.com"
	u := User{
		ID:           newTestUUID(),
		Email:        email,
		PasswordHash: "hash:" + randomHex(16),
		DisplayName:  "测试",
		CreatedAt:    time.Now().UTC(),
	}
	created, err := pg.CreateUser(ctx, u)
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if created.ID != u.ID || created.Email != email {
		t.Fatalf("创建用户返回不符：%+v", created)
	}
	if _, err := pg.CreateUser(ctx, u); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("重复邮箱应返回 ErrEmailTaken，实际 %v", err)
	}

	byEmail, err := pg.UserByEmail(ctx, email)
	if err != nil || byEmail.ID != u.ID {
		t.Fatalf("UserByEmail: %+v, %v", byEmail, err)
	}
	if _, err := pg.UpdateUserDisplayName(ctx, u.ID, "新名字"); err != nil {
		t.Fatalf("UpdateUserDisplayName: %v", err)
	}

	deviceID := "BKL-TEST-" + randomHex(6)
	claimHash := "hmac-sha256$" + randomHex(32)
	if err := pg.SeedDevice(ctx, Device{ID: deviceID, Model: "BKL1"}, claimHash); err != nil {
		t.Fatalf("SeedDevice: %v", err)
	}
	claim, err := pg.ClaimCodeHash(ctx, deviceID)
	if err != nil || claim.Claimed {
		t.Fatalf("初始声明码：%+v, %v", claim, err)
	}

	bound, err := pg.BindDevice(ctx, deviceID, u.ID, "通勤车")
	if err != nil {
		t.Fatalf("BindDevice: %v", err)
	}
	if bound.ClaimedBy == nil || *bound.ClaimedBy != u.ID || bound.State != StateClaimed {
		t.Fatalf("绑定结果不符：%+v", bound)
	}
	claim, err = pg.ClaimCodeHash(ctx, deviceID)
	if err != nil || !claim.Claimed {
		t.Fatalf("绑定后声明码状态：%+v, %v", claim, err)
	}
	list, err := pg.DevicesByOwner(ctx, u.ID)
	if err != nil || len(list) != 1 || list[0].ID != deviceID {
		t.Fatalf("DevicesByOwner: %+v, %v", list, err)
	}

	if err := pg.UnbindDevice(ctx, deviceID, u.ID); err != nil {
		t.Fatalf("UnbindDevice: %v", err)
	}
	unbound, err := pg.Device(ctx, deviceID)
	if err != nil {
		t.Fatalf("解绑后 Device: %v", err)
	}
	if unbound.ClaimedBy != nil || unbound.State != StateClaimable {
		t.Fatalf("解绑后状态不符：%+v", unbound)
	}
	if unbound.ClaimedAt == nil {
		t.Fatal("解绑不应清空 claimed_at")
	}
	if err := pg.UnbindDevice(ctx, deviceID, u.ID); !errors.Is(err, ErrNotBound) {
		t.Fatalf("重复解绑应返回 ErrNotBound，实际 %v", err)
	}

	points := []TelemetryPoint{
		{DeviceID: deviceID, Seq: 1, Time: time.Now().UTC(), Lat: 31.2, Lon: 121.4},
		{DeviceID: deviceID, Seq: 2, Time: time.Now().UTC(), Lat: 31.3, Lon: 121.5},
	}
	if n, err := pg.InsertTelemetry(ctx, points); err != nil || n != 2 {
		t.Fatalf("InsertTelemetry: n=%d err=%v", n, err)
	}
	if n, err := pg.InsertTelemetry(ctx, points); err != nil || n != 0 {
		t.Fatalf("重复 InsertTelemetry: n=%d err=%v", n, err)
	}

	at := time.Now().UTC()
	if err := pg.UpsertStatus(ctx, Status{DeviceID: deviceID, Online: true, Firmware: "0.1.0", At: at}); err != nil {
		t.Fatalf("UpsertStatus: %v", err)
	}
	withStatus, err := pg.Device(ctx, deviceID)
	if err != nil || withStatus.FWVersion != "0.1.0" || withStatus.LastSeenAt == nil {
		t.Fatalf("状态未同步到设备：%+v, %v", withStatus, err)
	}
	if err := pg.TouchLastSeen(ctx, deviceID, at.Add(time.Minute)); err != nil {
		t.Fatalf("TouchLastSeen: %v", err)
	}
}
