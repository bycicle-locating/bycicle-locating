package store

import (
	"context"
	"testing"
	"time"
)

func TestMemoryEventIdempotent(t *testing.T) {
	m := NewMemory()
	e := Event{
		DeviceID: "BKL-2026-000001",
		Seq:      7,
		Time:     time.Now().UTC(),
		Name:     "battery_low",
		Level:    "warn",
		Data:     map[string]any{"mv": 3300},
	}
	ctx := context.Background()
	if err := m.InsertEvent(ctx, e); err != nil {
		t.Fatalf("InsertEvent: %v", err)
	}
	if err := m.InsertEvent(ctx, e); err != nil {
		t.Fatalf("重复 InsertEvent: %v", err)
	}
	if got := len(m.Events()); got != 1 {
		t.Fatalf("重复事件应只保留一条，实际 %d", got)
	}
}
