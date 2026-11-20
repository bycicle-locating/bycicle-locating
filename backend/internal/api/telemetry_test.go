package api

import (
	"net/http"
	"net/url"
	"reflect"
	"testing"
	"time"

	"github.com/bycicle-locating/backend/internal/store"
)

func TestTelemetryRequiresCurrentOwner(t *testing.T) {
	srv, mem := newTestServer(t)
	defer srv.Close()
	ownerToken, owner := register(t, srv.URL, "telemetry-owner@example.com")
	otherToken, _ := register(t, srv.URL, "telemetry-other@example.com")
	ownerID := owner["user"].(map[string]any)["id"].(string)
	bound := time.Now().UTC().Add(-time.Hour)
	const deviceID = "BKL-2026-000321"
	mem.PutDevice(store.Device{ID: deviceID, ClaimedBy: &ownerID, ClaimedAt: &bound}, "")

	for _, route := range []string{"/location", "/track"} {
		base := srv.URL + "/v1/devices/"
		if status, _ := request(t, http.MethodGet, base+deviceID+route, "", nil); status != http.StatusUnauthorized {
			t.Fatalf("%s 无 JWT 返回 %d", route, status)
		}
		status, denied := request(t, http.MethodGet, base+deviceID+route, otherToken, nil)
		missingStatus, missing := request(t, http.MethodGet, base+"BKL-2026-000999"+route, otherToken, nil)
		if status != http.StatusForbidden || missingStatus != status || !reflect.DeepEqual(denied, missing) {
			t.Fatalf("%s 应统一拒绝非车主和不存在的设备，实际 %d/%d", route, status, missingStatus)
		}
	}

	base := srv.URL + "/v1/devices/" + deviceID
	if _, err := mem.InsertTelemetry(t.Context(), []store.TelemetryPoint{{
		DeviceID: deviceID, Seq: 1, Time: bound.Add(time.Minute), ReceivedAt: bound.Add(time.Minute), Fix: 0,
	}}); err != nil {
		t.Fatal(err)
	}
	if status, body := request(t, http.MethodGet, base+"/location", ownerToken, nil); status != http.StatusNotFound || body["error"] != "not_found" {
		t.Fatalf("车主仅有无定位上报时应得到 404 not_found，实际 %d %+v", status, body)
	}
	status, body := request(t, http.MethodGet, base+"/track", ownerToken, nil)
	if points, ok := body["points"].([]any); status != http.StatusOK || !ok || len(points) != 0 {
		t.Fatalf("车主无轨迹时应得到空数组，实际 %d %+v", status, body)
	}
}

func TestLocationAndTrackUseSequenceWithinBinding(t *testing.T) {
	srv, mem := newTestServer(t)
	defer srv.Close()
	token, owner := register(t, srv.URL, "telemetry-track@example.com")
	ownerID := owner["user"].(map[string]any)["id"].(string)
	bound := time.Now().UTC().Add(-time.Hour).Truncate(time.Second)
	const deviceID = "BKL-2026-000321"
	mem.PutDevice(store.Device{ID: deviceID, ClaimedBy: &ownerID, ClaimedAt: &bound}, "")
	point := func(seq uint32, minutes, received int) store.TelemetryPoint {
		return store.TelemetryPoint{
			DeviceID: deviceID, Seq: seq, Time: bound.Add(time.Duration(minutes) * time.Minute),
			ReceivedAt: bound.Add(time.Duration(received) * time.Minute),
			Lat:        31.2, Lon: 121.4, SpeedMPS: 3.5, CourseDeg: 180, Fix: 3,
		}
	}
	valid2D := point(11, 15, 20)
	valid2D.Fix, valid2D.Lat, valid2D.Lon = 2, 0, 0
	noFix := point(101, 16, 20)
	noFix.Fix, noFix.Lat, noFix.Lon = 0, 0, 0
	if _, err := mem.InsertTelemetry(t.Context(), []store.TelemetryPoint{
		point(10, 10, 20), point(12, 5, 20), valid2D,
		point(99, 8, -1), point(100, -2, 20), noFix,
	}); err != nil {
		t.Fatal(err)
	}

	base := srv.URL + "/v1/devices/" + deviceID
	status, latest := request(t, http.MethodGet, base+"/location", token, nil)
	if status != http.StatusOK || latest["seq"] != float64(12) || latest["deviceId"] != deviceID ||
		latest["ts"] != bound.Add(5*time.Minute).Format(time.RFC3339) || latest["speedMps"] != 3.5 {
		t.Fatalf("最新位置应按当前绑定可见点的最大 seq，实际 %d %+v", status, latest)
	}
	for _, test := range []struct {
		query string
		want  []float64
	}{
		{"?limit=2", []float64{11, 12}},
		{"?since=" + url.QueryEscape(bound.Add(6*time.Minute).Format(time.RFC3339)), []float64{10, 11}},
	} {
		status, body := request(t, http.MethodGet, base+"/track"+test.query, token, nil)
		points, ok := body["points"].([]any)
		if status != http.StatusOK || !ok || len(points) != len(test.want) {
			t.Fatalf("轨迹响应不符：%d %+v", status, body)
		}
		for i, want := range test.want {
			if got := points[i].(map[string]any)["seq"]; got != want {
				t.Fatalf("轨迹点 %d 的 seq = %v，期望 %v", i, got, want)
			}
		}
	}

	for _, query := range []string{"?since=invalid", "?since=%ZZ", "?limit=0", "?limit=abc", "?limit=99999999999999999999999999x"} {
		if status, _ := request(t, http.MethodGet, base+"/track"+query, token, nil); status != http.StatusBadRequest {
			t.Fatalf("非法 query %s 返回 %d", query, status)
		}
	}
}

func TestTrackDefaultsTo24HoursAndClampsTo500(t *testing.T) {
	srv, mem := newTestServer(t)
	defer srv.Close()
	token, owner := register(t, srv.URL, "telemetry-limit@example.com")
	ownerID := owner["user"].(map[string]any)["id"].(string)
	now := time.Now().UTC()
	bound := now.Add(-48 * time.Hour)
	const deviceID = "BKL-2026-000322"
	mem.PutDevice(store.Device{ID: deviceID, ClaimedBy: &ownerID, ClaimedAt: &bound}, "")
	points := make([]store.TelemetryPoint, 0, 506)
	for seq := uint32(1); seq <= 505; seq++ {
		points = append(points, store.TelemetryPoint{DeviceID: deviceID, Seq: seq, Time: now.Add(-time.Hour), ReceivedAt: now, Fix: 3})
	}
	points = append(points, store.TelemetryPoint{DeviceID: deviceID, Seq: 506, Time: now.Add(-25 * time.Hour), ReceivedAt: now, Fix: 3})
	if _, err := mem.InsertTelemetry(t.Context(), points); err != nil {
		t.Fatal(err)
	}

	base := srv.URL + "/v1/devices/" + deviceID + "/track"
	for _, test := range []struct {
		query       string
		first, last float64
	}{
		{"", 6, 505},
		{"?limit=1000", 6, 505},
		{"?limit=99999999999999999999999999", 6, 505},
		{"?limit=1000&since=0001-01-01T00:00:00Z", 7, 506},
	} {
		status, body := request(t, http.MethodGet, base+test.query, token, nil)
		got, ok := body["points"].([]any)
		if status != http.StatusOK || !ok || len(got) != 500 {
			t.Fatalf("轨迹应返回 500 点，实际状态 %d、%d 点", status, len(got))
		}
		if got[0].(map[string]any)["seq"] != test.first || got[len(got)-1].(map[string]any)["seq"] != test.last {
			t.Fatalf("轨迹边界序号应为 %v 和 %v，query=%s", test.first, test.last, test.query)
		}
	}
}
