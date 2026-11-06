package auth

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func testTokens(t *testing.T) (*Tokens, time.Time) {
	t.Helper()
	tokens, err := NewTokens(strings.Repeat("s", 32), time.Hour, "bkl-test")
	if err != nil {
		t.Fatalf("NewTokens: %v", err)
	}
	now := time.Date(2026, 11, 6, 12, 0, 0, 0, time.UTC)
	return tokens.WithClock(func() time.Time { return now }), now
}

func TestIssueAndParse(t *testing.T) {
	tokens, now := testTokens(t)
	token, expires, err := tokens.Issue("user-1", "a@example.com")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if !expires.Equal(now.Add(time.Hour)) {
		t.Fatalf("expires：期望 %v，实际 %v", now.Add(time.Hour), expires)
	}
	claims, err := tokens.Parse(token)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if claims.Subject != "user-1" || claims.Email != "a@example.com" || claims.Issuer != "bkl-test" {
		t.Fatalf("claims 不符：%+v", claims)
	}
}

func TestParseRejectsTamper(t *testing.T) {
	tokens, _ := testTokens(t)
	token, _, err := tokens.Issue("user-1", "a@example.com")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("token 格式异常：%q", token)
	}
	parts[1] = parts[1][:len(parts[1])-1] + "A"
	if _, err := tokens.Parse(strings.Join(parts, ".")); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("篡改后应拒绝，实际 %v", err)
	}
}

func TestParseExpired(t *testing.T) {
	tokens, now := testTokens(t)
	token, _, err := tokens.Issue("user-1", "a@example.com")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	later := tokens.WithClock(func() time.Time { return now.Add(2 * time.Hour) })
	if _, err := later.Parse(token); !errors.Is(err, ErrExpiredToken) {
		t.Fatalf("过期后应拒绝，实际 %v", err)
	}
}

func TestParseRejectsNoneAlg(t *testing.T) {
	tokens, _ := testTokens(t)
	token, _, err := tokens.Issue("user-1", "a@example.com")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	parts := strings.Split(token, ".")
	header, _ := json.Marshal(map[string]string{"alg": "none", "typ": "JWT"})
	parts[0] = base64.RawURLEncoding.EncodeToString(header)
	if _, err := tokens.Parse(strings.Join(parts, ".")); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("alg=none 应拒绝，实际 %v", err)
	}
}

func TestNewTokensRejectsShortSecret(t *testing.T) {
	if _, err := NewTokens("short", time.Hour, "issuer"); err == nil {
		t.Fatal("短 secret 应被拒绝")
	}
}
