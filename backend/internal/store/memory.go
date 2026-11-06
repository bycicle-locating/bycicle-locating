package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Memory 是内存实现，用于单元测试与无数据库的本地开发。
//
// 它把 Postgres 实现必须提供的保证（幂等、绑定原子性）也用同一套语义实现，
// 因此 ingest/device 的测试可以直接跑在它上面。
type Memory struct {
	mu        sync.Mutex
	now       func() time.Time
	devices   map[string]*Device
	claims    map[string]string // deviceID -> 声明码哈希
	users     map[string]User
	emails    map[string]string // 小写邮箱 -> userID
	seen      map[pointKey]struct{}
	eventSeen map[pointKey]struct{}
	events    []Event
	status    map[string]Status
	points    map[string][]TelemetryPoint
	binding   []bindingRecord
}

type pointKey struct {
	deviceID string
	seq      uint32
}

type bindingRecord struct {
	DeviceID string
	UserID   string
	BoundAt  time.Time
	Unbound  *time.Time
}

// NewMemory 创建一个空的内存存储。
func NewMemory() *Memory {
	return &Memory{
		now:       time.Now,
		devices:   make(map[string]*Device),
		claims:    make(map[string]string),
		users:     make(map[string]User),
		emails:    make(map[string]string),
		seen:      make(map[pointKey]struct{}),
		eventSeen: make(map[pointKey]struct{}),
		status:    make(map[string]Status),
		points:    make(map[string][]TelemetryPoint),
	}
}

// WithClock 替换时钟，供测试固定时间。
func (m *Memory) WithClock(now func() time.Time) *Memory {
	m.now = now
	return m
}

// PutDevice 注册一台设备并写入声明码哈希（测试辅助，不参与 Store 接口）。
func (m *Memory) PutDevice(d Device, claimCodeHash string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.putDeviceLocked(d, claimCodeHash)
}

// SeedDevice 实现 DeviceSeeder，供启动时注册演示设备。
func (m *Memory) SeedDevice(_ context.Context, d Device, claimCodeHash string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.putDeviceLocked(d, claimCodeHash)
	return nil
}

func (m *Memory) putDeviceLocked(d Device, claimCodeHash string) {
	if d.State == "" {
		d.State = StateClaimable
	}
	m.devices[d.ID] = &d
	if claimCodeHash != "" {
		m.claims[d.ID] = claimCodeHash
	}
}

// InsertTelemetry 幂等写入：已存在的 (deviceID, seq) 被跳过，返回新增条数。
func (m *Memory) InsertTelemetry(_ context.Context, points []TelemetryPoint) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	inserted := 0
	for _, p := range points {
		key := pointKey{deviceID: p.DeviceID, seq: p.Seq}
		if _, ok := m.seen[key]; ok {
			continue
		}
		m.seen[key] = struct{}{}
		if p.ReceivedAt.IsZero() {
			p.ReceivedAt = m.now()
		}
		m.points[p.DeviceID] = append(m.points[p.DeviceID], p)
		inserted++
	}
	return inserted, nil
}

// InsertEvent 幂等写入：已存在的 (deviceID, seq) 被跳过。
func (m *Memory) InsertEvent(_ context.Context, e Event) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := pointKey{deviceID: e.DeviceID, seq: e.Seq}
	if _, ok := m.eventSeen[key]; ok {
		return nil
	}
	m.eventSeen[key] = struct{}{}
	if e.ReceivedAt.IsZero() {
		e.ReceivedAt = m.now()
	}
	m.events = append(m.events, e)
	return nil
}

// UpsertStatus 更新设备在线状态与最近活跃时间。
func (m *Memory) UpsertStatus(_ context.Context, s Status) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	if s.At.IsZero() {
		s.At = now
	}
	m.status[s.DeviceID] = s
	if d, ok := m.devices[s.DeviceID]; ok {
		// last_seen_at 是服务端接收时间，不能被设备时钟影响。
		t := now
		d.LastSeenAt = &t
		if s.Firmware != "" {
			d.FWVersion = s.Firmware
		}
	}
	return nil
}

// Device 按 ID 查询。
func (m *Memory) Device(_ context.Context, deviceID string) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[deviceID]
	if !ok {
		return Device{}, ErrNotFound
	}
	return *d, nil
}

// ClaimCodeHash 返回声明码哈希与使用状态；哈希在绑定后仍保留，语义见 Store。
func (m *Memory) ClaimCodeHash(_ context.Context, deviceID string) (ClaimState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[deviceID]
	if !ok {
		return ClaimState{}, ErrNotFound
	}
	h, ok := m.claims[deviceID]
	if !ok || h == "" {
		// 未登记声明码：产线数据缺失，按"不存在"处理
		return ClaimState{}, ErrNotFound
	}
	return ClaimState{Hash: h, Claimed: d.ClaimedBy != nil}, nil
}

// BindDevice 原子绑定并占用声明码：claimed_by 非空期间该码不可再用于绑定，
// 解绑（claimed_by 置空）后恢复可用。
func (m *Memory) BindDevice(_ context.Context, deviceID, userID, label string) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[deviceID]
	if !ok {
		return Device{}, ErrNotFound
	}
	if d.ClaimedBy != nil {
		return Device{}, ErrAlreadyBound
	}
	now := m.now()
	owner := userID
	d.ClaimedBy = &owner
	d.ClaimedAt = &now
	d.State = StateClaimed
	if label != "" {
		d.Label = label
	}
	// 有意不删除 m.claims[deviceID]：保留哈希才能区分"声明码错误"与"已被绑定"。
	// "已使用"由 claimed_by 表达，而不是由哈希消失表达。
	m.binding = append(m.binding, bindingRecord{DeviceID: deviceID, UserID: userID, BoundAt: now})
	return *d, nil
}

// UnbindDevice 解除绑定，保留轨迹与审计。
func (m *Memory) UnbindDevice(_ context.Context, deviceID, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[deviceID]
	if !ok {
		return ErrNotFound
	}
	if d.ClaimedBy == nil || *d.ClaimedBy != userID {
		return ErrNotBound
	}
	now := m.now()
	d.ClaimedBy = nil
	d.State = StateClaimable
	for i := len(m.binding) - 1; i >= 0; i-- {
		if m.binding[i].DeviceID == deviceID && m.binding[i].Unbound == nil {
			m.binding[i].Unbound = &now
			break
		}
	}
	return nil
}

// TouchLastSeen 更新活跃时间。
func (m *Memory) TouchLastSeen(_ context.Context, deviceID string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if d, ok := m.devices[deviceID]; ok {
		t := at
		d.LastSeenAt = &t
	}
	return nil
}

// CreateUser 写入账号；邮箱按小写唯一。
func (m *Memory) CreateUser(_ context.Context, u User) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u.Email = strings.ToLower(strings.TrimSpace(u.Email))
	if u.ID == "" || u.Email == "" {
		return User{}, fmt.Errorf("store: 用户 ID 与邮箱不能为空")
	}
	if _, ok := m.emails[u.Email]; ok {
		return User{}, ErrEmailTaken
	}
	if u.CreatedAt.IsZero() {
		u.CreatedAt = m.now()
	}
	m.users[u.ID] = u
	m.emails[u.Email] = u.ID
	return u, nil
}

// UserByEmail 按小写邮箱查询。
func (m *Memory) UserByEmail(_ context.Context, email string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, ok := m.emails[strings.ToLower(strings.TrimSpace(email))]
	if !ok {
		return User{}, ErrNotFound
	}
	u, ok := m.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

// UserByID 按 ID 查询。
func (m *Memory) UserByID(_ context.Context, id string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	return u, nil
}

// UpdateUserDisplayName 更新昵称；空字符串表示清空。
func (m *Memory) UpdateUserDisplayName(_ context.Context, id, displayName string) (User, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	u, ok := m.users[id]
	if !ok {
		return User{}, ErrNotFound
	}
	u.DisplayName = displayName
	m.users[id] = u
	return u, nil
}

// DevicesByOwner 返回车主名下设备，按绑定时间倒序。
func (m *Memory) DevicesByOwner(_ context.Context, userID string) ([]Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Device, 0)
	for _, d := range m.devices {
		if d.ClaimedBy != nil && *d.ClaimedBy == userID {
			out = append(out, *d)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		var ti, tj time.Time
		if out[i].ClaimedAt != nil {
			ti = *out[i].ClaimedAt
		}
		if out[j].ClaimedAt != nil {
			tj = *out[j].ClaimedAt
		}
		return ti.After(tj)
	})
	return out, nil
}

// Points 返回某设备的全部轨迹点（测试用），按 seq 升序。
func (m *Memory) Points(deviceID string) []TelemetryPoint {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := append([]TelemetryPoint(nil), m.points[deviceID]...)
	sort.Slice(out, func(i, j int) bool { return out[i].Seq < out[j].Seq })
	return out
}

// Events 返回全部事件（测试用）。
func (m *Memory) Events() []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Event(nil), m.events...)
}

// Status 返回设备最近一次状态（测试用）。
func (m *Memory) Status(deviceID string) (Status, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.status[deviceID]
	return s, ok
}

// String 便于日志里识别当前实现。
func (m *Memory) String() string { return fmt.Sprintf("store.Memory(devices=%d)", len(m.devices)) }
