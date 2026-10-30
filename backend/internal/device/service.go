// Package device 实现设备的绑定与解绑。
//
// 安全边界都在这里：声明码哈希校验、绑定期间锁定该码、以及"解绑只能由车主发起"。
// HTTP 层只做鉴权与转发，不重复实现这些判断。
package device

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/bycicle-locating/backend/internal/store"
)

// 对外错误。API 层据此映射 HTTP 状态码，且对外文案不得泄露设备是否存在。
var (
	ErrInvalidClaim = errors.New("device: 声明码无效")
	ErrAlreadyBound = errors.New("device: 设备已被绑定")
	ErrNotFound     = errors.New("device: 设备不存在")
	ErrForbidden    = errors.New("device: 无权操作该设备")
)

// claimCode 是产线写入 NFC 标签的 16 字符 Base32 串（80 bit 熵）。
var claimCodePattern = regexp.MustCompile(`^[A-Z2-7]{16}$`)

// Hasher 计算与校验声明码。
type Hasher interface {
	Hash(secret string) (string, error)
	Verify(storedHash, secret string) bool
}

// Service 是绑定领域服务。
type Service struct {
	store  store.Store
	hasher Hasher
}

// New 构造绑定服务。
func New(st store.Store, h Hasher) *Service {
	return &Service{store: st, hasher: h}
}

// Bind 把设备绑定到用户。
//
// 判定顺序是安全设计的一部分，不要调换：
//  1. 声明码格式非法 → ErrInvalidClaim；
//  2. 设备不存在 → ErrInvalidClaim（与声明码错误对外一致，避免枚举）；
//  3. 声明码与存储哈希不符 → ErrInvalidClaim（**先校验，再看是否已绑定**：
//     否则任何知道 deviceId 的人都能探出该车的注册状态）；
//  4. 声明码正确但设备已绑定 → ErrAlreadyBound（持有真实标签的人才走到这里）；
//  5. 通过 → 原子绑定。
func (s *Service) Bind(ctx context.Context, deviceID, claimCode, userID, label string) (store.Device, error) {
	if userID == "" {
		return store.Device{}, ErrForbidden
	}
	claim := strings.ToUpper(claimCode)
	if !claimCodePattern.MatchString(claim) {
		return store.Device{}, ErrInvalidClaim
	}

	state, err := s.store.ClaimCodeHash(ctx, deviceID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return store.Device{}, ErrInvalidClaim
	case err != nil:
		return store.Device{}, fmt.Errorf("device: 读取声明码: %w", err)
	}

	if !s.hasher.Verify(state.Hash, claim) {
		return store.Device{}, ErrInvalidClaim
	}
	if state.Claimed {
		return store.Device{}, ErrAlreadyBound
	}

	d, err := s.store.BindDevice(ctx, deviceID, userID, label)
	switch {
	case errors.Is(err, store.ErrAlreadyBound):
		return store.Device{}, ErrAlreadyBound
	case errors.Is(err, store.ErrNotFound):
		return store.Device{}, ErrInvalidClaim
	case err != nil:
		return store.Device{}, fmt.Errorf("device: 绑定设备: %w", err)
	}
	return d, nil
}

// Unbind 解除绑定，只能由当前车主发起。
//
// 这里**不**接受任何来自设备端或物理按键的请求：若长按就能解绑，
// 偷车者拿到车后一按键即可让车辆脱离车主的监控范围。
func (s *Service) Unbind(ctx context.Context, deviceID, userID string) error {
	if userID == "" {
		return ErrForbidden
	}
	d, err := s.store.Device(ctx, deviceID)
	if errors.Is(err, store.ErrNotFound) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("device: 读取设备: %w", err)
	}
	if d.ClaimedBy == nil || *d.ClaimedBy != userID {
		return ErrForbidden
	}
	if err := s.store.UnbindDevice(ctx, deviceID, userID); err != nil {
		if errors.Is(err, store.ErrNotBound) {
			return ErrForbidden
		}
		return fmt.Errorf("device: 解绑: %w", err)
	}
	return nil
}

// Get 读取设备；调用方必须先校验鉴权，本方法不做权限判断。
func (s *Service) Get(ctx context.Context, deviceID string) (store.Device, error) {
	d, err := s.store.Device(ctx, deviceID)
	if errors.Is(err, store.ErrNotFound) {
		return store.Device{}, ErrNotFound
	}
	if err != nil {
		return store.Device{}, fmt.Errorf("device: 读取设备: %w", err)
	}
	return d, nil
}

// HMACHasher 用 HMAC-SHA256 保护声明码。
//
// 为什么不是 argon2id：声明码是 80 bit 随机值而非用户口令，字典攻击不成立，
// 而绑定是低频操作，没有必要付出慢哈希的 CPU 代价。pepper（服务端密钥）保证
// 即使数据库泄露，攻击者也无法离线穷举。
type HMACHasher struct {
	pepper []byte
}

// NewHMACHasher 要求 pepper 至少 16 字节；短密钥直接拒绝启动。
func NewHMACHasher(pepper string) (*HMACHasher, error) {
	if len(pepper) < 16 {
		return nil, errors.New("device: CLAIM_PEPPER 至少需要 16 字节")
	}
	return &HMACHasher{pepper: []byte(pepper)}, nil
}

// Hash 返回 `hmac-sha256$<base64>` 形式，便于将来并存别的算法。
func (h *HMACHasher) Hash(secret string) (string, error) {
	mac := hmac.New(sha256.New, h.pepper)
	if _, err := mac.Write([]byte(secret)); err != nil {
		return "", fmt.Errorf("device: 计算哈希: %w", err)
	}
	return "hmac-sha256$" + base64.RawStdEncoding.EncodeToString(mac.Sum(nil)), nil
}

// Verify 用 hmac.Equal 做恒定时间比较。
func (h *HMACHasher) Verify(storedHash, secret string) bool {
	if storedHash == "" {
		return false
	}
	got, err := h.Hash(secret)
	if err != nil {
		return false
	}
	return hmac.Equal([]byte(storedHash), []byte(got))
}
