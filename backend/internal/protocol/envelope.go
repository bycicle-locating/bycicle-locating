// Package protocol 实现 docs/protocol.md 定义的设备↔云线格式。
//
// 本包是唯一允许把 JSON 字节翻译成领域消息的地方：固件侧对应 main/proto，
// App 侧对应 core/models。改字段先改 docs/protocol.md。
package protocol

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"time"
)

// Version 是当前支持的信封主版本。
const Version = 1

const (
	// MaxPayloadBytes 单条 MQTT 报文上限，与固件侧缓冲一致。
	MaxPayloadBytes = 4096
	// MaxPointsPerBatch 单条 telemetry 最多携带的点数。
	MaxPointsPerBatch = 60
)

// Type 是信封 type 字段。
type Type string

const (
	TypeTelemetry Type = "telemetry"
	TypeEvent     Type = "event"
	TypeStatus    Type = "status"
	TypeCmdAck    Type = "cmd_ack"
)

// 事件与等级枚举，见 protocol.md §5。
var (
	eventNames = map[string]bool{
		"motion": true, "geofence_exit": true, "geofence_enter": true,
		"tamper": true, "low_battery": true, "power_on": true,
		"power_off": true, "gnss_lost": true,
	}
	eventLevels = map[string]bool{"info": true, "warn": true, "critical": true}
)

// 解码错误。调用方用 errors.Is 判断，避免解析字符串。
var (
	ErrEmpty              = errors.New("protocol: 空报文")
	ErrTooLarge           = errors.New("protocol: 报文超过上限")
	ErrMalformed          = errors.New("protocol: JSON 格式错误")
	ErrUnsupportedVersion = errors.New("protocol: 不支持的信封版本")
	ErrUnknownType        = errors.New("protocol: 未知报文类型")
	ErrInvalidDevice      = errors.New("protocol: 设备 ID 非法")
	ErrInvalidPayload     = errors.New("protocol: 载荷校验失败")
)

// 产线格式严格为 BKL-<年>-<6 位序列>；夹具/开发设备允许其它安全字符组合。
var (
	deviceIDFactory = regexp.MustCompile(`^BKL-[0-9]{4}-[0-9]{6}$`)
	deviceIDLoose   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{5,63}$`)
)

// Header 是所有报文共有的信封字段。
type Header struct {
	Version   int
	DeviceID  string
	Seq       uint32
	Timestamp time.Time
	Kind      Type
	Firmware  string
	Battery   *Battery
	Network   *Network
}

// Battery 与 Network 是可选的电量/信号快照。
type Battery struct {
	Millivolts int  `json:"mv"`
	Percent    *int `json:"pct,omitempty"`
}

// Network 是蜂窝信号质量。
type Network struct {
	RSRP *int `json:"rsrp,omitempty"`
	RSSI *int `json:"rssi,omitempty"`
}

// Message 是解码后的设备上行报文，恰好有一个载荷字段非空。
type Message struct {
	Header
	Telemetry *Telemetry
	Event     *Event
	Status    *Status
	Ack       *CmdAck
}

// Point 是一个轨迹点。单位固定为 SI：米、米/秒、度。
//
// 每个点自带 Seq：设备维护单一单调计数器，采样一次占一个号。
// 因此 (DeviceID, Seq) 在全部报文类型之间唯一，可直接作为去重与主键。
type Point struct {
	Seq       uint32    `json:"seq"`
	Time      time.Time `json:"t"`
	Lat       float64   `json:"lat"`
	Lon       float64   `json:"lon"`
	SpeedMPS  float64   `json:"spd"`
	CourseDeg float64   `json:"crs"`
	AltM      *float64  `json:"alt,omitempty"`
	HDOP      *float64  `json:"hdop,omitempty"`
	Fix       int       `json:"fix"`
	AccuracyM *float64  `json:"acc,omitempty"`
}

// Telemetry 是一批轨迹点。
type Telemetry struct {
	Points  []Point
	Dropped int
}

// Event 是告警或状态变更。
type Event struct {
	Name  string
	Level string
	Lat   *float64
	Lon   *float64
	Data  map[string]any
}

// Status 是在线状态，retained 发布。
type Status struct {
	Online bool
	GPSFix *bool
	BLE    *bool
}

// CmdAck 是对云端指令的确认。
type CmdAck struct {
	CmdID  string
	OK     bool
	Error  string
	Result map[string]any
}

// envelope 是线格式的原始结构，仅本包使用。
type envelope struct {
	V       int            `json:"v"`
	ID      string         `json:"id"`
	Seq     uint32         `json:"seq"`
	TS      time.Time      `json:"ts"`
	Type    Type           `json:"type"`
	FW      string         `json:"fw,omitempty"`
	Battery *Battery       `json:"battery,omitempty"`
	Net     *Network       `json:"net,omitempty"`
	Points  []Point        `json:"points,omitempty"`
	Dropped int            `json:"dropped,omitempty"`
	Event   string         `json:"event,omitempty"`
	Level   string         `json:"level,omitempty"`
	Lat     *float64       `json:"lat,omitempty"`
	Lon     *float64       `json:"lon,omitempty"`
	Data    map[string]any `json:"data,omitempty"`
	Online  *bool          `json:"online,omitempty"`
	GPSFix  *bool          `json:"gpsFix,omitempty"`
	BLE     *bool          `json:"ble,omitempty"`
	CmdID   string         `json:"cmdId,omitempty"`
	OK      *bool          `json:"ok,omitempty"`
	Error   string         `json:"error,omitempty"`
	Result  map[string]any `json:"result,omitempty"`
}

// Decode 解析并校验一条上行报文。
//
// 这是本包唯一的入口：调用方拿到的是已经过校验的强类型消息，不需要再关心
// 字段缺省、单位换算或版本兼容。任何不合规的报文都会返回可判定的错误。
func Decode(raw []byte) (Message, error) {
	if len(raw) == 0 {
		return Message{}, ErrEmpty
	}
	if len(raw) > MaxPayloadBytes {
		return Message{}, fmt.Errorf("%w: %d > %d", ErrTooLarge, len(raw), MaxPayloadBytes)
	}

	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Message{}, fmt.Errorf("%w: %v", ErrMalformed, err)
	}
	if env.V != Version {
		return Message{}, fmt.Errorf("%w: v=%d", ErrUnsupportedVersion, env.V)
	}
	if !validDeviceID(env.ID) {
		return Message{}, fmt.Errorf("%w: %q", ErrInvalidDevice, env.ID)
	}
	if env.Seq == 0 {
		return Message{}, fmt.Errorf("%w: seq 必须大于 0", ErrInvalidPayload)
	}
	if env.TS.IsZero() {
		return Message{}, fmt.Errorf("%w: 缺少 ts", ErrInvalidPayload)
	}

	msg := Message{
		Header: Header{
			Version:   env.V,
			DeviceID:  env.ID,
			Seq:       env.Seq,
			Timestamp: env.TS.UTC(),
			Kind:      env.Type,
			Firmware:  env.FW,
			Battery:   env.Battery,
			Network:   env.Net,
		},
	}

	switch env.Type {
	case TypeTelemetry:
		tel, err := decodeTelemetry(env)
		if err != nil {
			return Message{}, err
		}
		msg.Telemetry = tel
	case TypeEvent:
		ev, err := decodeEvent(env)
		if err != nil {
			return Message{}, err
		}
		msg.Event = ev
	case TypeStatus:
		msg.Status = &Status{Online: env.Online != nil && *env.Online, GPSFix: env.GPSFix, BLE: env.BLE}
	case TypeCmdAck:
		if env.CmdID == "" {
			return Message{}, fmt.Errorf("%w: cmd_ack 缺少 cmdId", ErrInvalidPayload)
		}
		msg.Ack = &CmdAck{
			CmdID:  env.CmdID,
			OK:     env.OK != nil && *env.OK,
			Error:  env.Error,
			Result: env.Result,
		}
	default:
		return Message{}, fmt.Errorf("%w: %q", ErrUnknownType, env.Type)
	}

	return msg, nil
}

func decodeTelemetry(env envelope) (*Telemetry, error) {
	if len(env.Points) == 0 {
		return nil, fmt.Errorf("%w: telemetry 无轨迹点", ErrInvalidPayload)
	}
	if len(env.Points) > MaxPointsPerBatch {
		return nil, fmt.Errorf("%w: 单批 %d 点超过上限 %d", ErrInvalidPayload, len(env.Points), MaxPointsPerBatch)
	}
	for i := range env.Points {
		p := &env.Points[i]
		if p.Seq == 0 {
			return nil, fmt.Errorf("%w: 第 %d 点缺少 seq", ErrInvalidPayload, i)
		}
		if p.Lat < -90 || p.Lat > 90 {
			return nil, fmt.Errorf("%w: 第 %d 点 lat=%v 越界", ErrInvalidPayload, i, p.Lat)
		}
		if p.Lon < -180 || p.Lon > 180 {
			return nil, fmt.Errorf("%w: 第 %d 点 lon=%v 越界", ErrInvalidPayload, i, p.Lon)
		}
		if p.Fix != 0 && p.Fix != 2 && p.Fix != 3 {
			return nil, fmt.Errorf("%w: 第 %d 点 fix=%d 非法", ErrInvalidPayload, i, p.Fix)
		}
		if p.SpeedMPS < 0 {
			return nil, fmt.Errorf("%w: 第 %d 点 spd=%v 为负", ErrInvalidPayload, i, p.SpeedMPS)
		}
		p.Time = p.Time.UTC()
	}
	// 顺序错误时重排而不拒收：丢数据的代价高于掩盖固件 bug，
	// 顺序问题由固件自检测试负责发现。
	sort.SliceStable(env.Points, func(i, j int) bool {
		return env.Points[i].Time.Before(env.Points[j].Time)
	})
	return &Telemetry{Points: env.Points, Dropped: env.Dropped}, nil
}

func decodeEvent(env envelope) (*Event, error) {
	if !eventNames[env.Event] {
		return nil, fmt.Errorf("%w: 未知 event %q", ErrInvalidPayload, env.Event)
	}
	if env.Level != "" && !eventLevels[env.Level] {
		return nil, fmt.Errorf("%w: 未知 level %q", ErrInvalidPayload, env.Level)
	}
	level := env.Level
	if level == "" {
		level = "info"
	}
	return &Event{Name: env.Event, Level: level, Lat: env.Lat, Lon: env.Lon, Data: env.Data}, nil
}

func validDeviceID(id string) bool {
	return deviceIDFactory.MatchString(id) || deviceIDLoose.MatchString(id)
}
