package user

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Hasher 抽象密码哈希，便于测试替换。
type Hasher interface {
	Hash(password string) (string, error)
	Verify(encoded, password string) bool
}

// Argon2id 使用 OWASP 推荐量级的 argon2id 参数。
type Argon2id struct {
	memory      uint32
	iterations  uint32
	parallelism uint8
	saltLen     uint32
	keyLen      uint32
}

// NewArgon2id 返回生产参数：64 MiB、3 次迭代、2 路并行。
func NewArgon2id() *Argon2id {
	return &Argon2id{
		memory:      64 * 1024,
		iterations:  3,
		parallelism: 2,
		saltLen:     16,
		keyLen:      32,
	}
}

// Hash 返回 argon2id$v=19$m=...,t=...,p=...$salt$hash。
func (h *Argon2id) Hash(password string) (string, error) {
	salt := make([]byte, h.saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("user: 生成盐: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, h.iterations, h.memory, h.parallelism, h.keyLen)
	return fmt.Sprintf("argon2id$v=19$m=%d,t=%d,p=%d$%s$%s",
		h.memory, h.iterations, h.parallelism,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// Verify 解析编码后的哈希并用常量时间比较。
func (h *Argon2id) Verify(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "argon2id" || parts[1] != "v=19" {
		return false
	}
	var memory, iterations uint32
	var parallelism uint8
	if _, err := fmt.Sscanf(parts[2], "m=%d,t=%d,p=%d", &memory, &iterations, &parallelism); err != nil {
		return false
	}
	if memory == 0 || iterations == 0 || parallelism == 0 {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(want) == 0 {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, iterations, memory, parallelism, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}
