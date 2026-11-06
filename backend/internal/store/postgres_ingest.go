package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func (p *Postgres) InsertTelemetry(ctx context.Context, points []TelemetryPoint) (int, error) {
	if len(points) == 0 {
		return 0, nil
	}
	batch := &pgx.Batch{}
	now := time.Now().UTC()
	for _, pt := range points {
		received := pt.ReceivedAt
		if received.IsZero() {
			received = now
		}
		batch.Queue(`INSERT INTO telemetry_points
			(device_id, seq, ts, received_at, lat, lon, speed_mps, course_deg, alt_m, hdop, fix, quality)
			VALUES (@deviceID, @seq, @ts, @receivedAt, @lat, @lon, @speed, @course, @alt, @hdop, @fix, 0)
			ON CONFLICT (device_id, seq) DO NOTHING`,
			pgx.NamedArgs{
				"deviceID":   pt.DeviceID,
				"seq":        int64(pt.Seq),
				"ts":         pt.Time,
				"receivedAt": received,
				"lat":        pt.Lat,
				"lon":        pt.Lon,
				"speed":      pt.SpeedMPS,
				"course":     pt.CourseDeg,
				"alt":        pt.AltM,
				"hdop":       pt.HDOP,
				"fix":        pt.Fix,
			})
	}
	results := p.pool.SendBatch(ctx, batch)
	defer func() { _ = results.Close() }()

	inserted := 0
	for range points {
		tag, err := results.Exec()
		if err != nil {
			return inserted, fmt.Errorf("store: 写入轨迹: %w", err)
		}
		inserted += int(tag.RowsAffected())
	}
	return inserted, nil
}

func (p *Postgres) InsertEvent(ctx context.Context, e Event) error {
	data := e.Data
	if data == nil {
		data = map[string]any{}
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return fmt.Errorf("store: 序列化事件数据: %w", err)
	}
	received := e.ReceivedAt
	if received.IsZero() {
		received = time.Now().UTC()
	}
	_, err = p.pool.Exec(ctx, `INSERT INTO events
		(device_id, seq, ts, received_at, type, level, lat, lon, data)
		VALUES (@deviceID, @seq, @ts, @receivedAt, @name, @level, @lat, @lon, @data)`,
		pgx.NamedArgs{
			"deviceID":   e.DeviceID,
			"seq":        int64(e.Seq),
			"ts":         e.Time,
			"receivedAt": received,
			"name":       e.Name,
			"level":      e.Level,
			"lat":        e.Lat,
			"lon":        e.Lon,
			"data":       raw,
		})
	if err != nil {
		return fmt.Errorf("store: 写入事件: %w", err)
	}
	return nil
}

func (p *Postgres) UpsertStatus(ctx context.Context, s Status) error {
	at := s.At
	if at.IsZero() {
		at = time.Now().UTC()
	}
	var one int
	err := p.pool.QueryRow(ctx, `WITH updated AS (
		UPDATE devices SET
			last_seen_at = @at,
			fw_version = CASE WHEN @firmware = '' THEN fw_version ELSE @firmware END
		WHERE id = @deviceID
		RETURNING 1
	)
	INSERT INTO device_status
		(device_id, online, firmware, battery_mv, at)
	VALUES (@deviceID, @online, @firmware, @battery, @at)
	ON CONFLICT (device_id) DO UPDATE SET
		online = EXCLUDED.online,
		firmware = EXCLUDED.firmware,
		battery_mv = EXCLUDED.battery_mv,
		at = EXCLUDED.at
	RETURNING 1`,
		pgx.NamedArgs{
			"deviceID": s.DeviceID,
			"online":   s.Online,
			"firmware": s.Firmware,
			"battery":  s.BatteryMV,
			"at":       at,
		}).Scan(&one)
	if err != nil {
		return fmt.Errorf("store: 写入设备状态: %w", err)
	}
	return nil
}
