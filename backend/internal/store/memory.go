package store

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

// Memory 是内存实现，用于单元测试与无数据库的本地开发。
//
// 它把 Postgres 实现必须提供的保证（幂等、绑定原子性）也用同一套语义实现，
// 因此 ingest/device 的测试可以直接跑在它上面。
type Memory struct {
	mu      sync.Mutex
	now     func() time.Time
	devices map[string]*Device
	claims  map[string]string // deviceID -> 声明码哈希
	seen    map[pointKey]struct{}
	events  []Event
	status  map[string]Status
	points  map[string][]TelemetryPoint
	binding []bindingRecord
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
		now:     time.Now,
		devices: make(map[string]*Device),
		claims:  make(map[string]string),
		seen:    make(map[pointKey]struct{}),
		status:  make(map[string]Status),
		points:  make(map[string][]TelemetryPoint),
	}
}

// WithClock 替换时钟，供测试固定时间。
func (m *Memory) WithClock(now func() time.Time) *Memory {
	m.now = now
	return m
}

// PutDevice 注册一台设备并写入声明码哈希（模拟产线上报）。
func (m *Memory) PutDevice(d Device, claimCodeHash string) {
	m.mu.Lock()
	defer m.mu.Unlock()
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

// InsertEvent 追加事件。
func (m *Memory) InsertEvent(_ context.Context, e Event) error {
	m.mu.Lock()
	defer m.mu.Unlock()
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
	m.status[s.DeviceID] = s
	if d, ok := m.devices[s.DeviceID]; ok {
		at := s.At
		if at.IsZero() {
			at = m.now()
		}
		d.LastSeenAt = &at
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

// BindDevice 原子绑定并烧毁声明码。
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
