package store

import (
	"cmp"
	"context"
	"slices"
	"time"
)

func (m *Memory) LatestTelemetry(ctx context.Context, deviceID, ownerID string) (TelemetryPoint, error) {
	points, err := m.TelemetrySince(ctx, deviceID, ownerID, time.Time{}, 1)
	if err != nil {
		return TelemetryPoint{}, err
	}
	if len(points) == 0 {
		return TelemetryPoint{}, ErrNotFound
	}
	return points[0], nil
}

func (m *Memory) TelemetrySince(ctx context.Context, deviceID, ownerID string, since time.Time, limit int) ([]TelemetryPoint, error) {
	points, err := m.visibleTelemetry(ctx, deviceID, ownerID, since)
	if err != nil {
		return nil, err
	}
	slices.SortFunc(points, func(a, b TelemetryPoint) int { return cmp.Compare(b.Seq, a.Seq) })
	points = points[:min(len(points), max(0, limit))]
	slices.Reverse(points)
	return points, nil
}

func (m *Memory) visibleTelemetry(ctx context.Context, deviceID, ownerID string, since time.Time) ([]TelemetryPoint, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	d := m.devices[deviceID]
	if d == nil || d.ClaimedBy == nil || ownerID == "" || *d.ClaimedBy != ownerID {
		return nil, ErrNotOwner
	}
	points := make([]TelemetryPoint, 0)
	if d.ClaimedAt == nil {
		return points, nil
	}
	for _, point := range m.points[deviceID] {
		if (point.Fix != 2 && point.Fix != 3) ||
			point.Time.Before(*d.ClaimedAt) || point.ReceivedAt.Before(*d.ClaimedAt) ||
			(!since.IsZero() && point.Time.Before(since)) {
			continue
		}
		points = append(points, point)
	}
	return points, nil
}
