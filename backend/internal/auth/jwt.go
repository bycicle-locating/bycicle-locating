// Package auth 负责签发与校验 JWT。
//
// 只实现 HS256，避免引入 JWT 库；解析时严格拒绝 alg=none 与其他算法。
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrInvalidToken = errors.New("auth: token 无效")
	ErrExpiredToken = errors.New("auth: token 已过期")
)

// Claims 是 JWT 载荷。sub 是 users.id（UUID 字符串）。
type Claims struct {
	Subject   string `json:"sub"`
	Email     string `json:"email,omitempty"`
	Issuer    string `json:"iss"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

// Tokens 签发与校验 HS256 token。
type Tokens struct {
	secret []byte
	ttl    time.Duration
	issuer string
	now    func() time.Time
}

// NewTokens 要求 secret 至少 32 字节。
func NewTokens(secret string, ttl time.Duration, issuer string) (*Tokens, error) {
	if len(secret) < 32 {
		return nil, errors.New("auth: JWT_SECRET 至少 32 字节")
	}
	if ttl <= 0 {
		ttl = 24 * time.Hour
	}
	if issuer == "" {
		issuer = "bicycle-locating"
	}
	return &Tokens{secret: []byte(secret), ttl: ttl, issuer: issuer, now: time.Now}, nil
}

// WithClock 供测试固定时间。
func (t *Tokens) WithClock(now func() time.Time) *Tokens {
	t.now = now
	return t
}

// Issue 为用户签发 token，返回过期时间（UTC）。
func (t *Tokens) Issue(subject, email string) (string, time.Time, error) {
	if !validSubject(subject) {
		return "", time.Time{}, errors.New("auth: subject 必须是 UUID")
	}
	now := t.now().UTC()
	expires := now.Add(t.ttl)
	header, err := json.Marshal(struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}{Alg: "HS256", Typ: "JWT"})
	if err != nil {
		return "", time.Time{}, fmt.Errorf("auth: 编码 header: %w", err)
	}
	payload, err := json.Marshal(Claims{
		Subject:   subject,
		Email:     email,
		Issuer:    t.issuer,
		IssuedAt:  now.Unix(),
		ExpiresAt: expires.Unix(),
	})
	if err != nil {
		return "", time.Time{}, fmt.Errorf("auth: 编码 claims: %w", err)
	}
	signing := b64(header) + "." + b64(payload)
	token := signing + "." + b64(t.sign(signing))
	return token, expires, nil
}

// Parse 校验签名、issuer 与 exp，返回 claims。
func (t *Tokens) Parse(token string) (Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return Claims{}, ErrInvalidToken
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return Claims{}, ErrInvalidToken
	}
	var header struct {
		Alg string `json:"alg"`
		Typ string `json:"typ"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return Claims{}, ErrInvalidToken
	}
	if header.Alg != "HS256" || (header.Typ != "" && header.Typ != "JWT") {
		return Claims{}, ErrInvalidToken
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return Claims{}, ErrInvalidToken
	}
	if !hmac.Equal(signature, t.sign(parts[0]+"."+parts[1])) {
		return Claims{}, ErrInvalidToken
	}
	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return Claims{}, ErrInvalidToken
	}
	var claims Claims
	if err := json.Unmarshal(payloadJSON, &claims); err != nil {
		return Claims{}, ErrInvalidToken
	}
	if !validSubject(claims.Subject) || claims.Issuer != t.issuer {
		return Claims{}, ErrInvalidToken
	}
	now := t.now().UTC().Unix()
	if claims.ExpiresAt <= now {
		return Claims{}, ErrExpiredToken
	}
	if claims.IssuedAt > now+60 {
		return Claims{}, ErrInvalidToken
	}
	return claims, nil
}

func (t *Tokens) sign(input string) []byte {
	mac := hmac.New(sha256.New, t.secret)
	_, _ = mac.Write([]byte(input))
	return mac.Sum(nil)
}

func b64(b []byte) string {
	return base64.RawURLEncoding.EncodeToString(b)
}

// validSubject 要求 sub 是标准 36 字符 UUID。Postgres 的 users.id 是 uuid 列，
// 非 UUID 的 sub 会在 CAST 时变成 500，因此在 token 边界就拒绝。
func validSubject(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if s[i] != '-' {
				return false
			}
			continue
		}
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') && (c < 'A' || c > 'F') {
			return false
		}
	}
	return true
}
