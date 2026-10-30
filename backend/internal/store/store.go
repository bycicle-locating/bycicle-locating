// Package store 定义持久化 seam。
//
// 调用方（ingest / device / api）只依赖这里的接口与模型，不感知 SQL。
// 当前只提供内存实现；Postgres 实现属于 M1，落地时不得把 pgx 类型泄漏到接口上。
package store

import (
	"context"
	"errors"
	"time"
)

// 领域错误。上层用 errors.Is 判断，避免字符串匹配。
var (
	ErrNotFound     = errors.New("store: 记录不存在")
	ErrAlreadyBound = errors.New("store: 设备已被绑定")
	ErrNotBound     = errors.New("store: 设备未被绑定")
)

// 设备状态，与 docs/pairing.md §4 一致。
const (
	StateFactory   = "FACTORY"
	StateClaimable = "CLAIMABLE"
	StateClaimed   = "CLAIMED"
)

// Device 是一台设备。
type Device struct {
	ID         string
	Model      string
	State      string
	ClaimedBy  *string
	ClaimedAt  *time.Time
	FWVersion  string
	Label      string
	LastSeenAt *time.Time
	Config     map[string]any
}

// TelemetryPoint 是落库形态的轨迹点：比线格式多了设备与骑行归属。
type TelemetryPoint struct {
	DeviceID   string
	Seq        uint32
	Time       time.Time
	Lat        float64
	Lon        float64
	SpeedMPS   float64
	CourseDeg  float64
	AltM       *float64
	HDOP       *float64
	Fix        int
	ReceivedAt time.Time
}

// Event 是落库形态的事件。
type Event struct {
	DeviceID   string
	Seq        uint32
	Time       time.Time
	Name       string
	Level      string
	Lat        *float64
	Lon        *float64
	Data       map[string]any
	ReceivedAt time.Time
}

// Status 是落库形态的在线状态。
type Status struct {
	DeviceID  string
	Online    bool
	Firmware  string
	BatteryMV *int
	At        time.Time
}

// ClaimState 是绑定判定所需的声明码状态。
type ClaimState struct {
	// Hash 是声明码的单向哈希，绑定后不删除。
	Hash string
	// Claimed 为真表示该声明码已被使用（设备已有车主）。
	Claimed bool
}

// Store 是持久化接口。实现必须保证：
//   - InsertTelemetry 对 (DeviceID, Seq) 幂等，返回实际新插入的条数；
//   - BindDevice 原子完成"校验未绑定 → 占用声明码 → 写车主"，并发下只有一个成功；
//   - 所有方法尊重 ctx 取消。
type Store interface {
	InsertTelemetry(ctx context.Context, points []TelemetryPoint) (inserted int, err error)
	InsertEvent(ctx context.Context, e Event) error
	UpsertStatus(ctx context.Context, s Status) error
	Device(ctx context.Context, deviceID string) (Device, error)
	// ClaimCodeHash 返回设备声明码的哈希与"是否已被使用"。
	//
	// **哈希在绑定后仍然保留**（只把 claimed 置真）。这样调用方可以先校验声明码，
	// 再判断是否已被绑定，从而做到：
	//   - 声明码错误             → 与"设备不存在"同样的外部错误，不泄露设备状态；
	//   - 声明码正确但已绑定      → 可以明确告知"已被绑定"，语义准确；
	//   - 设备不存在             → ErrNotFound。
	// 若绑定后就删掉哈希，就只能凭"设备已被绑定"对外应答，等于向任何知道 deviceId 的人
	// 暴露该车的注册状态。
	ClaimCodeHash(ctx context.Context, deviceID string) (ClaimState, error)
	// BindDevice 把设备绑定到用户。调用前 device 服务已校验声明码；
	// 本方法在同一次写操作里清空声明码并写入车主，已绑定时返回 ErrAlreadyBound。
	BindDevice(ctx context.Context, deviceID, userID, label string) (Device, error)
	// UnbindDevice 只写 claimed_by=NULL 并记录审计，不清除轨迹历史。
	UnbindDevice(ctx context.Context, deviceID, userID string) error
	// TouchLastSeen 更新设备活跃时间。
	TouchLastSeen(ctx context.Context, deviceID string, at time.Time) error
}
