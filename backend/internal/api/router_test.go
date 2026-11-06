package api

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/bycicle-locating/backend/internal/auth"
	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/store"
	"github.com/bycicle-locating/backend/internal/user"
)

type testHasher struct{}

func (testHasher) Hash(password string) (string, error) { return "h:" + password, nil }
func (testHasher) Verify(encoded, password string) bool { return encoded == "h:"+password }

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

var (
	testPassword  = randomHex(16)
	testPepper    = randomHex(24)
	testJWTSecret = randomHex(32)
)

func newTestServer(t *testing.T) (*httptest.Server, *store.Memory) {
	t.Helper()
	mem := store.NewMemory()
	devHasher, err := device.NewHMACHasher(testPepper)
	if err != nil {
		t.Fatalf("NewHMACHasher: %v", err)
	}
	devices := device.New(mem, devHasher)
	users, err := user.New(mem, testHasher{})
	if err != nil {
		t.Fatalf("user.New: %v", err)
	}
	tokens, err := auth.NewTokens(testJWTSecret, time.Hour, "bkl-test")
	if err != nil {
		t.Fatalf("NewTokens: %v", err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := New(devices, users, tokens, JWTAuthenticator{Tokens: tokens}, log)
	return httptest.NewServer(srv.Routes()), mem
}

func request(t *testing.T, method, url, token string, body any) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("编码请求: %v", err)
		}
	}
	req, err := http.NewRequest(method, url, &buf)
	if err != nil {
		t.Fatalf("创建请求: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("请求 %s %s: %v", method, url, err)
	}
	defer res.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil && err != io.EOF {
		t.Fatalf("解码响应: %v", err)
	}
	return res.StatusCode, out
}

func register(t *testing.T, base, email string) (string, map[string]any) {
	t.Helper()
	status, body := request(t, http.MethodPost, base+"/v1/auth/register", "", map[string]string{
		"email": email, "password": testPassword, "displayName": "车主",
	})
	if status != http.StatusCreated {
		t.Fatalf("注册状态：期望 201，实际 %d，响应 %+v", status, body)
	}
	token, _ := body["token"].(string)
	if token == "" {
		t.Fatalf("注册响应缺少 token：%+v", body)
	}
	return token, body
}

func TestRegisterLoginAndMe(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()

	token, body := register(t, srv.URL, "rider@example.com")
	userObj, _ := body["user"].(map[string]any)
	if userObj["email"] != "rider@example.com" {
		t.Fatalf("注册返回用户不符：%+v", userObj)
	}

	status, me := request(t, http.MethodGet, srv.URL+"/v1/users/me", token, nil)
	if status != http.StatusOK || me["email"] != "rider@example.com" {
		t.Fatalf("me：status=%d body=%+v", status, me)
	}

	status, patched := request(t, http.MethodPatch, srv.URL+"/v1/users/me", token, map[string]string{"displayName": "新名字"})
	if status != http.StatusOK || patched["displayName"] != "新名字" {
		t.Fatalf("patch：status=%d body=%+v", status, patched)
	}

	status, login := request(t, http.MethodPost, srv.URL+"/v1/auth/login", "", map[string]string{
		"email": "RIDER@example.com", "password": testPassword,
	})
	if status != http.StatusOK || login["token"] == "" {
		t.Fatalf("login：status=%d body=%+v", status, login)
	}
}

func TestUserErrors(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()
	register(t, srv.URL, "rider@example.com")

	status, body := request(t, http.MethodPost, srv.URL+"/v1/auth/register", "", map[string]string{
		"email": "rider@example.com", "password": testPassword,
	})
	if status != http.StatusConflict || body["error"] != "email_taken" {
		t.Fatalf("重复注册：status=%d body=%+v", status, body)
	}

	status, body = request(t, http.MethodPost, srv.URL+"/v1/auth/login", "", map[string]string{
		"email": "rider@example.com", "password": testPassword + "-wrong",
	})
	if status != http.StatusUnauthorized || body["error"] != "invalid_credentials" {
		t.Fatalf("错误密码：status=%d body=%+v", status, body)
	}

	status, _ = request(t, http.MethodGet, srv.URL+"/v1/users/me", "", nil)
	if status != http.StatusUnauthorized {
		t.Fatalf("无 token 访问 me：期望 401，实际 %d", status)
	}
}

func TestMyDevices(t *testing.T) {
	srv, mem := newTestServer(t)
	defer srv.Close()

	token, _ := register(t, srv.URL, "rider@example.com")
	devHasher, _ := device.NewHMACHasher(testPepper)
	hash, err := devHasher.Hash("ABCDEFGHIJKLMNOP")
	if err != nil {
		t.Fatalf("Hash: %v", err)
	}
	mem.PutDevice(store.Device{ID: "BKL-2026-000001", Model: "BKL1"}, hash)

	status, body := request(t, http.MethodPost, srv.URL+"/v1/devices:bind", token, map[string]string{
		"deviceId": "BKL-2026-000001", "claimCode": "ABCDEFGHIJKLMNOP", "label": "通勤车",
	})
	if status != http.StatusOK {
		t.Fatalf("绑定：status=%d body=%+v", status, body)
	}

	status, body = request(t, http.MethodGet, srv.URL+"/v1/users/me/devices", token, nil)
	devices, _ := body["devices"].([]any)
	if status != http.StatusOK || len(devices) != 1 {
		t.Fatalf("我的设备：status=%d body=%+v", status, body)
	}
	first, _ := devices[0].(map[string]any)
	if first["id"] != "BKL-2026-000001" || first["label"] != "通勤车" {
		t.Fatalf("设备 DTO 不符：%+v", first)
	}
}

func TestEmptyDeviceListIsArray(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()
	token, _ := register(t, srv.URL, "empty@example.com")
	status, body := request(t, http.MethodGet, srv.URL+"/v1/users/me/devices", token, nil)
	if status != http.StatusOK {
		t.Fatalf("空设备列表：status=%d body=%+v", status, body)
	}
	raw, _ := json.Marshal(body["devices"])
	if string(raw) != "[]" {
		t.Fatalf("空设备列表应为 []，实际 %s", raw)
	}
}

func TestUserResponsesAreNotCached(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()
	token, _ := register(t, srv.URL, "cache@example.com")

	req, err := http.NewRequest(http.MethodGet, srv.URL+"/v1/users/me", nil)
	if err != nil {
		t.Fatalf("创建请求: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("请求 me: %v", err)
	}
	defer res.Body.Close()
	if got := res.Header.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control 期望 no-store，实际 %q", got)
	}
}

func TestInvalidToken(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()
	status, _ := request(t, http.MethodGet, srv.URL+"/v1/users/me", "not-a-token", nil)
	if status != http.StatusUnauthorized {
		t.Fatalf("坏 token：期望 401，实际 %d", status)
	}
}

func TestEmailNormalizationInRegister(t *testing.T) {
	srv, _ := newTestServer(t)
	defer srv.Close()
	status, body := request(t, http.MethodPost, srv.URL+"/v1/auth/register", "", map[string]string{
		"email": "  Mixed@Example.COM ", "password": testPassword,
	})
	if status != http.StatusCreated {
		t.Fatalf("注册：status=%d body=%+v", status, body)
	}
	u, _ := body["user"].(map[string]any)
	if fmt.Sprint(u["email"]) != "mixed@example.com" {
		t.Fatalf("邮箱未归一化：%+v", u)
	}
}
