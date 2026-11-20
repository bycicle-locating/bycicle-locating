package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

func (p *Postgres) LatestTelemetry(ctx context.Context, deviceID, ownerID string) (TelemetryPoint, error) {
	points, err := p.TelemetrySince(ctx, deviceID, ownerID, time.Time{}, 1)
	if err != nil {
		return TelemetryPoint{}, err
	}
	if len(points) == 0 {
		return TelemetryPoint{}, ErrNotFound
	}
	return points[0], nil
}

func (p *Postgres) TelemetrySince(ctx context.Context, deviceID, ownerID string, since time.Time, limit int) ([]TelemetryPoint, error) {
	var start *time.Time
	if !since.IsZero() {
		start = &since
	}
	// 在读取坐标的同一条查询中限定当前车主，避免并发换绑时返回他人的位置。
	rows, err := p.pool.Query(ctx, `SELECT t.seq, t.ts, t.received_at, t.lat, t.lon,
		COALESCE(t.speed_mps, 0), COALESCE(t.course_deg, 0), t.alt_m, t.hdop, t.fix
		FROM telemetry_points t
		JOIN devices d ON d.id = t.device_id
		WHERE t.device_id = @deviceID AND CAST(d.claimed_by AS text) = @ownerID
			AND t.received_at >= d.claimed_at AND t.ts >= d.claimed_at
			AND t.fix IN (2, 3)
			AND t.lat IS NOT NULL AND t.lon IS NOT NULL
			AND (CAST(@since AS timestamptz) IS NULL OR t.ts >= @since)
		ORDER BY t.seq DESC LIMIT @limit`,
		pgx.NamedArgs{"deviceID": deviceID, "ownerID": ownerID, "since": start, "limit": max(0, limit)})
	if err != nil {
		return nil, fmt.Errorf("store: 查询轨迹点: %w", err)
	}
	defer rows.Close()

	points := make([]TelemetryPoint, 0)
	for rows.Next() {
		point := TelemetryPoint{DeviceID: deviceID}
		if err := rows.Scan(&point.Seq, &point.Time, &point.ReceivedAt, &point.Lat, &point.Lon,
			&point.SpeedMPS, &point.CourseDeg, &point.AltM, &point.HDOP, &point.Fix); err != nil {
			return nil, fmt.Errorf("store: 读取轨迹点: %w", err)
		}
		points = append(points, point)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读取轨迹点: %w", err)
	}
	if len(points) == 0 {
		owner, err := p.ownerOf(ctx, deviceID)
		if errors.Is(err, ErrNotFound) {
			return nil, ErrNotOwner
		}
		if err != nil {
			return nil, err
		}
		if owner == nil || *owner != ownerID {
			return nil, ErrNotOwner
		}
	}
	slices.Reverse(points)
	return points, nil
}
