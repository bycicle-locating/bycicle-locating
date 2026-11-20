package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"testing"

	"github.com/bycicle-locating/backend/internal/ingest"
	"github.com/bycicle-locating/backend/internal/mqtt"
	"github.com/bycicle-locating/backend/internal/store"
)

type ingestTestBus struct {
	mqtt.Bus
	handler mqtt.Handler
}

func (b *ingestTestBus) Subscribe(_ context.Context, _ string, handler mqtt.Handler) error {
	b.handler = handler
	return nil
}

func TestWireIngestRejectsMisroutedAndUnregisteredTelemetry(t *testing.T) {
	ctx := context.Background()
	const known = "BKL-2026-000001"
	const unknown = "BKL-2026-000099"

	for _, test := range []struct {
		name, topicID, suffix, payloadID string
		want                             int
	}{
		{name: "正常", topicID: known, suffix: "telemetry", payloadID: known, want: 1},
		{name: "类型与主题不符", topicID: known, suffix: "event", payloadID: known},
		{name: "设备与主题不符", topicID: unknown, suffix: "telemetry", payloadID: known},
		{name: "未注册设备", topicID: unknown, suffix: "telemetry", payloadID: unknown},
	} {
		t.Run(test.name, func(t *testing.T) {
			st := store.NewMemory()
			st.PutDevice(store.Device{ID: known, Model: "BKL1"}, "unused")
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			bus := &ingestTestBus{}
			if err := wireIngest(ctx, bus, ingest.New(st), logger); err != nil {
				t.Fatal(err)
			}

			topic := fmt.Sprintf("v1/device/%s/%s", test.topicID, test.suffix)
			if err := bus.handler(ctx, mqtt.Message{Topic: topic, Payload: testTelemetry(test.payloadID), QoS: 1}); err != nil {
				t.Fatalf("正常或永久无效的报文应正常结束处理: %v", err)
			}
			if got := len(st.Points(test.payloadID)); got != test.want {
				t.Fatalf("写入轨迹点数 = %d，期望 %d", got, test.want)
			}
		})
	}
}

type failingTelemetryStore struct {
	store.Store
	err error
}

func (s failingTelemetryStore) InsertTelemetry(context.Context, []store.TelemetryPoint) (int, error) {
	return 0, s.err
}

func TestWireIngestRetriesOnlyTemporaryStoreErrors(t *testing.T) {
	ctx := context.Background()
	const deviceID = "BKL-2026-000001"
	mem := store.NewMemory()
	mem.PutDevice(store.Device{ID: deviceID, Model: "BKL1"}, "unused")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	message := mqtt.Message{
		Topic: "v1/device/" + deviceID + "/telemetry", Payload: testTelemetry(deviceID), QoS: 1,
	}

	temporary := errors.New("数据库暂时不可用")
	for _, test := range []struct {
		name        string
		input, want error
	}{
		{name: "永久数据错误", input: store.ErrInvalidUplink},
		{name: "暂时故障", input: temporary, want: temporary},
	} {
		t.Run(test.name, func(t *testing.T) {
			bus := &ingestTestBus{}
			st := failingTelemetryStore{Store: mem, err: test.input}
			if err := wireIngest(ctx, bus, ingest.New(st), logger); err != nil {
				t.Fatal(err)
			}
			if got := bus.handler(ctx, message); !errors.Is(got, test.want) {
				t.Fatalf("处理结果为 %v，期望 %v", got, test.want)
			}
		})
	}
}

func testTelemetry(deviceID string) []byte {
	return fmt.Appendf(nil, `{"v":1,"id":%q,"seq":1,"ts":"2026-11-20T07:00:01Z","type":"telemetry","fw":"0.1.0","points":[{"seq":1,"t":"2026-11-20T07:00:00Z","lat":31.23,"lon":121.47,"spd":2.5,"crs":0,"fix":3}]}`, deviceID)
}
