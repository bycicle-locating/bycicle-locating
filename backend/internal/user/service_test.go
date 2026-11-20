package user

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/bycicle-locating/backend/internal/store"
)

type fakeHasher struct{}

func (fakeHasher) Hash(password string) (string, error) {
	sum := sha256.Sum256([]byte(password))
	return "h:" + hex.EncodeToString(sum[:]), nil
}

func (fakeHasher) Verify(encoded, password string) bool {
	got, _ := fakeHasher{}.Hash(password)
	return encoded == got
}

func newTestService(t *testing.T) (*Service, *store.Memory) {
	t.Helper()
	mem := store.NewMemory()
	svc, err := New(mem, fakeHasher{})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	return svc.WithClock(func() time.Time { return now }), mem
}

func TestRegisterAndLogin(t *testing.T) {
	svc, _ := newTestService(t)
	ctx := context.Background()

	u, err := svc.Register(ctx, "  Rider@Example.COM ", "password123", " 通勤车 ")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if u.ID == "" {
		t.Fatal("用户 ID 不能为空")
	}
	if u.Email != "rider@example.com" {
		t.Fatalf("邮箱未归一化：%q", u.Email)
	}
	if u.DisplayName != "通勤车" {
		t.Fatalf("昵称未 trim：%q", u.DisplayName)
	}
	if strings.Contains(u.PasswordHash, "password123") {
		t.Fatal("密码哈希不能包含明文")
	}

	logged, err := svc.Login(ctx, "RIDER@example.com", "password123")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if logged.ID != u.ID {
		t.Fatalf("登录用户不一致：%s != %s", logged.ID, u.ID)
	}
}

func TestRegisterRejectsDuplicateEmail(t *testing.T) {
	svc, _ := newTestService(t)
	ctx := context.Background()
	if _, err := svc.Register(ctx, "a@example.com", "password123", ""); err != nil {
		t.Fatalf("首次注册: %v", err)
	}
	if _, err := svc.Register(ctx, "A@EXAMPLE.COM", "password456", ""); !errors.Is(err, ErrEmailTaken) {
		t.Fatalf("重复邮箱应拒绝，实际 %v", err)
	}
}

func TestRegisterValidation(t *testing.T) {
	svc, _ := newTestService(t)
	ctx := context.Background()
	if _, err := svc.Register(ctx, "not-an-email", "password123", ""); !errors.Is(err, ErrInvalidEmail) {
		t.Fatalf("非法邮箱应拒绝，实际 %v", err)
	}
	if _, err := svc.Register(ctx, "a@example.com", "short", ""); !errors.Is(err, ErrWeakPassword) {
		t.Fatalf("弱密码应拒绝，实际 %v", err)
	}
	if _, err := svc.Register(ctx, "b@example.com", "password123", strings.Repeat("名", 65)); !errors.Is(err, ErrInvalidDisplayName) {
		t.Fatalf("超长昵称应拒绝，实际 %v", err)
	}
}

func TestLoginRejectsUnknownAndWrongPassword(t *testing.T) {
	svc, _ := newTestService(t)
	ctx := context.Background()
	if _, err := svc.Register(ctx, "a@example.com", "password123", ""); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if _, err := svc.Login(ctx, "missing@example.com", "password123"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("未知邮箱应统一失败，实际 %v", err)
	}
	if _, err := svc.Login(ctx, "a@example.com", "wrong-password"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("错误密码应统一失败，实际 %v", err)
	}
}

func TestUpdateProfile(t *testing.T) {
	svc, _ := newTestService(t)
	ctx := context.Background()
	u, err := svc.Register(ctx, "a@example.com", "password123", "旧名字")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	updated, err := svc.UpdateProfile(ctx, u.ID, " 新名字 ")
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if updated.DisplayName != "新名字" {
		t.Fatalf("昵称未更新：%q", updated.DisplayName)
	}
	cleared, err := svc.UpdateProfile(ctx, u.ID, "")
	if err != nil {
		t.Fatalf("清空昵称: %v", err)
	}
	if cleared.DisplayName != "" {
		t.Fatalf("昵称未清空：%q", cleared.DisplayName)
	}
}

func TestArgon2idRoundTrip(t *testing.T) {
	h := &Argon2id{memory: 1024, iterations: 1, parallelism: 1, saltLen: 16, keyLen: 32}
	encoded, err := h.Hash("password123")
	if err != nil {
		t.Fatalf("Hash: %v", err)
	}
	if !h.Verify(encoded, "password123") {
		t.Fatal("正确密码应通过")
	}
	if h.Verify(encoded, "wrong-password") {
		t.Fatal("错误密码不应通过")
	}
	if h.Verify("not-a-hash", "password123") {
		t.Fatal("非法哈希不应通过")
	}
}
