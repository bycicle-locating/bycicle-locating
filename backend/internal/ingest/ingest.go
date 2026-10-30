// Package ingest 把解码后的设备报文落入存储。
//
// Handle 是纯逻辑：不碰网络、不读全局状态，依赖通过构造函数注入，
// 因此可以用 store.Memory + 固定时钟完整单测。
package ingest

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/bycicle-locating/backend/internal/protocol"
	"github.com/bycicle-locating/backend/internal/store"
)

// Result 汇总一次处理的落库情况，供指标与日志使用。
type Result struct {
	Kind       protocol.Type
	Inserted   int
	Duplicates int
}

// Service 是报文入库入口。
type Service struct {
	store store.Store
	log   *slog.Logger
	now   func() time.Time
}

// Option 配置 Service。
type Option func(*Service)

// WithClock 替换时钟，测试用。
func WithClock(now func() time.Time) Option {
	return func(s *Service) { s.now = now }
}

// WithLogger 替换日志器。
func WithLogger(l *slog.Logger) Option {
	return func(s *Service) {
		if l != nil {
			s.log = l
		}
	}
}

// New 构造入库服务。
func New(st store.Store, opts ...Option) *Service {
	s := &Service{store: st, log: slog.Default(), now: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Handle 处理一条已通过 protocol.Decode 校验的报文。
//
// 幂等：同一 (deviceID, seq) 重复到达只落库一次，重复部分记入 Duplicates，
// 且不视为错误——设备重传是正常行为。
func (s *Service) Handle(ctx context.Context, msg protocol.Message) (Result, error) {
	res := Result{Kind: msg.Kind}
	now := s.now()

	switch msg.Kind {
	case protocol.TypeTelemetry:
		if msg.Telemetry == nil {
			return res, fmt.Errorf("ingest: telemetry 载荷缺失")
		}
		points := make([]store.TelemetryPoint, 0, len(msg.Telemetry.Points))
		for _, p := range msg.Telemetry.Points {
			points = append(points, store.TelemetryPoint{
				DeviceID:   msg.DeviceID,
				Seq:        p.Seq,
				Time:       p.Time,
				Lat:        p.Lat,
				Lon:        p.Lon,
				SpeedMPS:   p.SpeedMPS,
				CourseDeg:  p.CourseDeg,
				AltM:       p.AltM,
				HDOP:       p.HDOP,
				Fix:        p.Fix,
				ReceivedAt: now,
			})
		}

		inserted, err := s.store.InsertTelemetry(ctx, points)
		if err != nil {
			return res, fmt.Errorf("ingest: 写入轨迹点: %w", err)
		}
		res.Inserted = inserted
		res.Duplicates = len(points) - inserted

		if msg.Telemetry.Dropped > 0 {
			// 缓冲被撑满说明离线太久或上报长期失败，是需要人工关注的信号。
			s.log.Warn("设备缓冲丢点",
				"device", msg.DeviceID, "dropped", msg.Telemetry.Dropped, "seq", msg.Seq)
		}

	case protocol.TypeEvent:
		if msg.Event == nil {
			return res, fmt.Errorf("ingest: event 载荷缺失")
		}
		ev := store.Event{
			DeviceID:   msg.DeviceID,
			Seq:        msg.Seq,
			Time:       msg.Timestamp,
			Name:       msg.Event.Name,
			Level:      msg.Event.Level,
			Lat:        msg.Event.Lat,
			Lon:        msg.Event.Lon,
			Data:       msg.Event.Data,
			ReceivedAt: now,
		}
		if err := s.store.InsertEvent(ctx, ev); err != nil {
			return res, fmt.Errorf("ingest: 写入事件: %w", err)
		}
		res.Inserted = 1
		if msg.Event.Level == "critical" {
			s.log.Warn("设备严重事件", "device", msg.DeviceID, "event", msg.Event.Name)
		}

	case protocol.TypeStatus:
		if msg.Status == nil {
			return res, fmt.Errorf("ingest: status 载荷缺失")
		}
		st := store.Status{
			DeviceID:  msg.DeviceID,
			Online:    msg.Status.Online,
			Firmware:  msg.Firmware,
			BatteryMV: batteryMV(msg.Battery),
			At:        msg.Timestamp,
		}
		if err := s.store.UpsertStatus(ctx, st); err != nil {
			return res, fmt.Errorf("ingest: 更新状态: %w", err)
		}
		res.Inserted = 1

	case protocol.TypeCmdAck:
		// TODO(M1): 更新 commands 表状态（acked/failed/timeout）并唤醒等待中的请求。
		s.log.Info("收到指令确认",
			"device", msg.DeviceID, "cmdId", ackCmdID(msg.Ack))

	default:
		return res, fmt.Errorf("ingest: 未知报文类型 %q", msg.Kind)
	}

	if err := s.store.TouchLastSeen(ctx, msg.DeviceID, now); err != nil {
		// 活跃时间只是辅助信息，失败不应导致整条报文被判失败。
		s.log.Warn("更新 last_seen 失败", "device", msg.DeviceID, "err", err)
	}
	return res, nil
}

func batteryMV(b *protocol.Battery) *int {
	if b == nil {
		return nil
	}
	mv := b.Millivolts
	return &mv
}

func ackCmdID(a *protocol.CmdAck) string {
	if a == nil {
		return ""
	}
	return a.CmdID
}
