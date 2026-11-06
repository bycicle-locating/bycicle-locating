// Package user 实现账号注册、登录与资料。
//
// 密码哈希与输入校验在这里；HTTP 层只做鉴权、解码和错误映射。
package user

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/bycicle-locating/backend/internal/store"
)

var (
	ErrInvalidEmail       = errors.New("user: 邮箱格式错误")
	ErrWeakPassword       = errors.New("user: 密码长度不符合要求")
	ErrInvalidDisplayName = errors.New("user: 昵称过长")
	ErrEmailTaken         = errors.New("user: 邮箱已被占用")
	ErrInvalidCredentials = errors.New("user: 邮箱或密码错误")
	ErrNotFound           = errors.New("user: 用户不存在")
)

const (
	minPasswordBytes = 8
	maxPasswordBytes = 128
	maxDisplayRunes  = 64
)

// Service 是账号领域服务。
type Service struct {
	store     store.Store
	hasher    Hasher
	now       func() time.Time
	dummyHash string
}

// New 构造服务；dummyHash 用于登录失败时保持近似恒定耗时。
func New(st store.Store, h Hasher) (*Service, error) {
	dummy, err := h.Hash("dummy-password-for-timing")
	if err != nil {
		return nil, fmt.Errorf("user: 生成 dummy hash: %w", err)
	}
	return &Service{store: st, hasher: h, now: time.Now, dummyHash: dummy}, nil
}

// WithClock 供测试固定时间。
func (s *Service) WithClock(now func() time.Time) *Service {
	s.now = now
	return s
}

// Register 创建账号。邮箱按小写归一化，密码只存 argon2id 哈希。
func (s *Service) Register(ctx context.Context, email, password, displayName string) (store.User, error) {
	normalized, err := normalizeEmail(email)
	if err != nil {
		return store.User{}, err
	}
	if err := validatePassword(password); err != nil {
		return store.User{}, err
	}
	name, err := normalizeDisplayName(displayName)
	if err != nil {
		return store.User{}, err
	}
	hash, err := s.hasher.Hash(password)
	if err != nil {
		return store.User{}, fmt.Errorf("user: 哈希密码: %w", err)
	}
	id, err := newUUID()
	if err != nil {
		return store.User{}, err
	}
	u := store.User{
		ID:           id,
		Email:        normalized,
		PasswordHash: hash,
		DisplayName:  name,
		CreatedAt:    s.now().UTC(),
	}
	created, err := s.store.CreateUser(ctx, u)
	if errors.Is(err, store.ErrEmailTaken) {
		return store.User{}, ErrEmailTaken
	}
	if err != nil {
		return store.User{}, fmt.Errorf("user: 创建账号: %w", err)
	}
	return created, nil
}

// Login 校验邮箱与密码。账号不存在与密码错误返回同一个错误。
func (s *Service) Login(ctx context.Context, email, password string) (store.User, error) {
	normalized, err := normalizeEmail(email)
	if err != nil {
		// 邮箱格式错误也走一次 dummy 校验，避免与"账号不存在"产生明显时序差。
		s.hasher.Verify(s.dummyHash, password)
		return store.User{}, ErrInvalidCredentials
	}
	u, err := s.store.UserByEmail(ctx, normalized)
	if errors.Is(err, store.ErrNotFound) {
		s.hasher.Verify(s.dummyHash, password)
		return store.User{}, ErrInvalidCredentials
	}
	if err != nil {
		return store.User{}, fmt.Errorf("user: 读取账号: %w", err)
	}
	if !s.hasher.Verify(u.PasswordHash, password) {
		return store.User{}, ErrInvalidCredentials
	}
	return u, nil
}

// ByID 读取当前用户。
func (s *Service) ByID(ctx context.Context, id string) (store.User, error) {
	u, err := s.store.UserByID(ctx, id)
	if errors.Is(err, store.ErrNotFound) {
		return store.User{}, ErrNotFound
	}
	if err != nil {
		return store.User{}, fmt.Errorf("user: 读取用户: %w", err)
	}
	return u, nil
}

// UpdateProfile 只允许改昵称；空字符串表示清空。
func (s *Service) UpdateProfile(ctx context.Context, id, displayName string) (store.User, error) {
	name, err := normalizeDisplayName(displayName)
	if err != nil {
		return store.User{}, err
	}
	u, err := s.store.UpdateUserDisplayName(ctx, id, name)
	if errors.Is(err, store.ErrNotFound) {
		return store.User{}, ErrNotFound
	}
	if err != nil {
		return store.User{}, fmt.Errorf("user: 更新资料: %w", err)
	}
	return u, nil
}

// Devices 返回当前车主名下设备。
func (s *Service) Devices(ctx context.Context, userID string) ([]store.Device, error) {
	devices, err := s.store.DevicesByOwner(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("user: 查询设备: %w", err)
	}
	return devices, nil
}

func normalizeEmail(raw string) (string, error) {
	email := strings.ToLower(strings.TrimSpace(raw))
	if email == "" || len(email) > 254 {
		return "", ErrInvalidEmail
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email {
		return "", ErrInvalidEmail
	}
	return email, nil
}

func validatePassword(password string) error {
	if len(password) < minPasswordBytes || len(password) > maxPasswordBytes {
		return ErrWeakPassword
	}
	return nil
}

func normalizeDisplayName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if utf8.RuneCountInString(name) > maxDisplayRunes {
		return "", ErrInvalidDisplayName
	}
	return name, nil
}
