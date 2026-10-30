package ingest

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/bycicle-locating/backend/internal/protocol"
	"github.com/bycicle-locating/backend/internal/store"
)

const testDevice = "BKL-2026-000123"

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newService(t *testing.T) (*Service, *store.Memory) {
	t.Helper()
	mem := store.NewMemory()
	mem.PutDevice(store.Device{ID: testDevice, Model: "BKL1"}, "unused")
	fixed := time.Date(2026, 10, 30, 6, 12, 3, 0, time.UTC)
	return New(mem, WithLogger(quietLogger()), WithClock(func() time.Time { return fixed })), mem
}

func telemetryJSON(t *testing.T, seqs ...int) []byte {
	t.Helper()
	type point struct {
		Seq int       `json:"seq"`
		T   time.Time `json:"t"`
		Lat float64   `json:"lat"`
		Lon float64   `json:"lon"`
		Spd float64   `json:"spd"`
		Crs float64   `json:"crs"`
		Fix int       `json:"fix"`
	}
	points := make([]point, 0, len(seqs))
	base := time.Date(2026, 10, 30, 6, 11, 58, 0, time.UTC)
	for i, s := range seqs {
		points = append(points, point{
			Seq: s,
			T:   base.Add(time.Duration(i) * 10 * time.Second),
			Lat: 31.2304 + float64(i)*0.0003,
			Lon: 121.4737,
			Spd: 6.2,
			Crs: 187.5,
			Fix: 3,
		})
	}
	payload, err := json.Marshal(map[string]any{
		"v":      1,
		"id":     testDevice,
		"seq":    seqs[len(seqs)-1],
		"ts":     base.Add(time.Duration(len(seqs)) * 10 * time.Second),
		"type":   "telemetry",
		"fw":     "0.1.0",
		"points": points,
	})
	if err != nil {
		t.Fatalf("构造测试载荷失败: %v", err)
	}
	return payload
}

func TestHandleTelemetryInsertsPoints(t *testing.T) {
	svc, mem := newService(t)

	msg, err := protocol.Decode(telemetryJSON(t, 1, 2, 3))
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}

	res, err := svc.Handle(context.Background(), msg)
	if err != nil {
		t.Fatalf("Handle 失败: %v", err)
	}
	if res.Inserted != 3 || res.Duplicates != 0 {
		t.Fatalf("期望 3 条新点 0 重复，实际 inserted=%d duplicates=%d", res.Inserted, res.Duplicates)
	}
	if got := len(mem.Points(testDevice)); got != 3 {
		t.Fatalf("期望存储 3 个点，实际 %d", got)
	}
}

func TestHandleTelemetryIsIdempotent(t *testing.T) {
	svc, mem := newService(t)
	raw := telemetryJSON(t, 10, 11)

	for i := 0; i < 3; i++ {
		msg, err := protocol.Decode(raw)
		if err != nil {
			t.Fatalf("第 %d 次 Decode 失败: %v", i, err)
		}
		res, err := svc.Handle(context.Background(), msg)
		if err != nil {
			t.Fatalf("第 %d 次 Handle 失败: %v", i, err)
		}
		switch i {
		case 0:
			if res.Inserted != 2 || res.Duplicates != 0 {
				t.Fatalf("首次应插入 2 条，实际 inserted=%d duplicates=%d", res.Inserted, res.Duplicates)
			}
		default:
			if res.Inserted != 0 || res.Duplicates != 2 {
				t.Fatalf("重传应全部去重，实际 inserted=%d duplicates=%d", res.Inserted, res.Duplicates)
			}
		}
	}
	// 三次投递后存储里仍应只有 2 个点——这是幂等键 (deviceID, seq) 的直接后果。
	if got := len(mem.Points(testDevice)); got != 2 {
		t.Fatalf("期望存储 2 个点，实际 %d", got)
	}
}

func TestHandleTelemetrySortsPointsByTime(t *testing.T) {
	svc, mem := newService(t)
	payload, err := json.Marshal(map[string]any{
		"v":    1,
		"id":   testDevice,
		"seq":  3,
		"ts":   "2026-10-30T06:12:30Z",
		"type": "telemetry",
		"points": []map[string]any{
			{"seq": 3, "t": "2026-10-30T06:12:20Z", "lat": 31.2308, "lon": 121.4750, "fix": 3},
			{"seq": 1, "t": "2026-10-30T06:12:00Z", "lat": 31.2304, "lon": 121.4737, "fix": 3},
			{"seq": 2, "t": "2026-10-30T06:12:10Z", "lat": 31.2306, "lon": 121.4744, "fix": 3},
		},
	})
	if err != nil {
		t.Fatalf("构造载荷失败: %v", err)
	}
	msg, err := protocol.Decode(payload)
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if _, err := svc.Handle(context.Background(), msg); err != nil {
		t.Fatalf("Handle 失败: %v", err)
	}

	points := mem.Points(testDevice)
	if len(points) != 3 {
		t.Fatalf("期望 3 个点，实际 %d", len(points))
	}
	for i := 1; i < len(points); i++ {
		if points[i-1].Time.After(points[i].Time) {
			t.Fatalf("轨迹点未按时间排序: %v 在 %v 之前", points[i-1].Time, points[i].Time)
		}
	}
}

func TestHandleStatusMarksDeviceOnline(t *testing.T) {
	svc, mem := newService(t)
	raw := []byte(`{"v":1,"id":"` + testDevice + `","seq":99,` +
		`"ts":"2026-10-30T06:12:03Z","type":"status","online":true,"fw":"0.1.0"}`)

	msg, err := protocol.Decode(raw)
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if _, err := svc.Handle(context.Background(), msg); err != nil {
		t.Fatalf("Handle 失败: %v", err)
	}

	st, ok := mem.Status(testDevice)
	if !ok || !st.Online {
		t.Fatalf("期望设备在线，实际 %+v", st)
	}
	dev, err := mem.Device(context.Background(), testDevice)
	if err != nil {
		t.Fatalf("读取设备失败: %v", err)
	}
	if dev.LastSeenAt == nil {
		t.Fatal("期望 last_seen 被更新")
	}
	if dev.FWVersion != "0.1.0" {
		t.Fatalf("期望固件版本 0.1.0，实际 %q", dev.FWVersion)
	}
}
