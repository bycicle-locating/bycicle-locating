package telemetry

import (
	"context"
	"time"

	"github.com/bycicle-locating/backend/internal/store"
)

const maxTrackPoints = 500

type Service struct {
	store store.Store
}

func New(st store.Store) *Service {
	return &Service{store: st}
}

func (s *Service) Latest(ctx context.Context, deviceID, ownerID string) (store.TelemetryPoint, error) {
	return s.store.LatestTelemetry(ctx, deviceID, ownerID)
}

func (s *Service) Track(ctx context.Context, deviceID, ownerID string, since *time.Time, limit int) ([]store.TelemetryPoint, error) {
	var start time.Time
	if since == nil {
		start = time.Now().UTC().Add(-24 * time.Hour)
	} else {
		start = *since
	}
	if limit <= 0 || limit > maxTrackPoints {
		limit = maxTrackPoints
	}
	return s.store.TelemetrySince(ctx, deviceID, ownerID, start, limit)
}
