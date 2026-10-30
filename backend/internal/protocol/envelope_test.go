package protocol

import (
	"errors"
	"testing"
)

const devID = "BKL-2026-000123"

func envelopeJSON(extra string) []byte {
	return []byte(`{"v":1,"id":"` + devID + `","seq":5,"ts":"2026-10-30T06:12:03Z",` + extra + `}`)
}

func TestDecodeTelemetry(t *testing.T) {
	raw := envelopeJSON(`"type":"telemetry","points":[` +
		`{"seq":5,"t":"2026-10-30T06:11:58Z","lat":31.2304,"lon":121.4737,"spd":6.2,"crs":187.5,"fix":3}]`)

	msg, err := Decode(raw)
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if msg.Kind != TypeTelemetry {
		t.Fatalf("期望类型 telemetry，实际 %q", msg.Kind)
	}
	if msg.DeviceID != devID {
		t.Fatalf("设备 ID 解析错误: %q", msg.DeviceID)
	}
	if len(msg.Telemetry.Points) != 1 {
		t.Fatalf("期望 1 个点，实际 %d", len(msg.Telemetry.Points))
	}
}

func TestDecodeRejectsBadInput(t *testing.T) {
	cases := []struct {
		name string
		raw  []byte
		want error
	}{
		{"空载荷", nil, ErrEmpty},
		{"非法 JSON", []byte("{"), ErrMalformed},
		{"版本不支持", []byte(`{"v":2,"id":"` + devID + `","seq":1,"ts":"2026-10-30T06:12:03Z","type":"status"}`), ErrUnsupportedVersion},
		{"设备 ID 非法", []byte(`{"v":1,"id":"a","seq":1,"ts":"2026-10-30T06:12:03Z","type":"status"}`), ErrInvalidDevice},
		{"未知类型", envelopeJSON(`"type":"weather"`), ErrUnknownType},
		{"缺少轨迹点", envelopeJSON(`"type":"telemetry","points":[]`), ErrInvalidPayload},
		{"点缺少 seq", envelopeJSON(`"type":"telemetry","points":[{"t":"2026-10-30T06:11:58Z","lat":31.2,"lon":121.4,"fix":3}]`), ErrInvalidPayload},
		{"纬度越界", envelopeJSON(`"type":"telemetry","points":[{"seq":5,"t":"2026-10-30T06:11:58Z","lat":91,"lon":121.4,"fix":3}]`), ErrInvalidPayload},
		{"fix 非法", envelopeJSON(`"type":"telemetry","points":[{"seq":5,"t":"2026-10-30T06:11:58Z","lat":31.2,"lon":121.4,"fix":1}]`), ErrInvalidPayload},
		{"未知事件", envelopeJSON(`"type":"event","event":"explode"`), ErrInvalidPayload},
		{"未知等级", envelopeJSON(`"type":"event","event":"motion","level":"fatal"`), ErrInvalidPayload},
		{"ack 缺 cmdId", envelopeJSON(`"type":"cmd_ack"`), ErrInvalidPayload},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Decode(tc.raw)
			if !errors.Is(err, tc.want) {
				t.Fatalf("期望错误 %v，实际 %v", tc.want, err)
			}
		})
	}
}

func TestDecodeRejectsOversizedPayload(t *testing.T) {
	raw := make([]byte, MaxPayloadBytes+1)
	if _, err := Decode(raw); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("期望 ErrTooLarge，实际 %v", err)
	}
}

func TestDecodeEventDefaultsToInfo(t *testing.T) {
	msg, err := Decode(envelopeJSON(`"type":"event","event":"tamper"`))
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if msg.Event.Level != "info" {
		t.Fatalf("期望默认等级 info，实际 %q", msg.Event.Level)
	}
}

func TestDecodeStatusOffline(t *testing.T) {
	msg, err := Decode(envelopeJSON(`"type":"status","online":false`))
	if err != nil {
		t.Fatalf("Decode 失败: %v", err)
	}
	if msg.Status == nil || msg.Status.Online {
		t.Fatalf("期望离线状态，实际 %+v", msg.Status)
	}
}

func TestParseTopic(t *testing.T) {
	ok := map[string]Type{
		"v1/device/" + devID + "/telemetry": TypeTelemetry,
		"v1/device/" + devID + "/event":     TypeEvent,
		"v1/device/" + devID + "/status":    TypeStatus,
		"v1/device/" + devID + "/cmd/ack":   TypeCmdAck,
	}
	for topic, want := range ok {
		if got, kind, err := ParseTopic(topic); err != nil || kind != want || got != devID {
			t.Fatalf("%s: 得到 (%q,%q,%v)，期望 (%q,%q)", topic, got, kind, err, devID, want)
		}
	}

	bad := []string{
		"v2/device/" + devID + "/telemetry",
		"v1/device/" + devID + "/weather",
		"v1/device//telemetry",
		"v1/device/" + devID,
		"",
	}
	for _, topic := range bad {
		if _, _, err := ParseTopic(topic); !errors.Is(err, ErrBadTopic) {
			t.Fatalf("%q 应被拒绝，实际 err=%v", topic, err)
		}
	}
}

func TestEncodeCommand(t *testing.T) {
	raw, err := EncodeCommand(Command{CmdID: "abc", Name: CmdBind})
	if err != nil {
		t.Fatalf("EncodeCommand 失败: %v", err)
	}
	if len(raw) == 0 {
		t.Fatal("期望非空载荷")
	}

	if _, err := EncodeCommand(Command{CmdID: "abc", Name: "explode"}); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("未知指令应被拒绝，实际 %v", err)
	}
	if _, err := EncodeCommand(Command{Name: CmdLocate}); !errors.Is(err, ErrInvalidPayload) {
		t.Fatalf("缺少 cmdId 应被拒绝，实际 %v", err)
	}
}
