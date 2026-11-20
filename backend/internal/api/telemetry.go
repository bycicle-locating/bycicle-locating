package api

import (
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/bycicle-locating/backend/internal/store"
)

type locationDTO struct {
	DeviceID  string    `json:"deviceId"`
	Seq       uint32    `json:"seq"`
	TS        time.Time `json:"ts"`
	Lat       float64   `json:"lat"`
	Lon       float64   `json:"lon"`
	SpeedMPS  float64   `json:"speedMps"`
	CourseDeg float64   `json:"courseDeg"`
	AltM      *float64  `json:"altM,omitempty"`
	HDOP      *float64  `json:"hdop,omitempty"`
	Fix       int       `json:"fix"`
}

type trackResponse struct {
	Points []locationDTO `json:"points"`
}

func toLocationDTO(p store.TelemetryPoint) locationDTO {
	return locationDTO{
		DeviceID: p.DeviceID, Seq: p.Seq, TS: p.Time.UTC(), Lat: p.Lat, Lon: p.Lon,
		SpeedMPS: p.SpeedMPS, CourseDeg: p.CourseDeg, AltM: p.AltM, HDOP: p.HDOP, Fix: p.Fix,
	}
}

func (s *Server) handleLocation(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	userID, err := s.auth.User(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "请先登录")
		return
	}
	point, err := s.telemetry.Latest(r.Context(), r.PathValue("deviceID"), userID)
	if err != nil {
		s.writeTelemetryError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toLocationDTO(point))
}

func (s *Server) handleTrack(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	userID, err := s.auth.User(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "请先登录")
		return
	}
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "查询参数格式错误")
		return
	}
	var since *time.Time
	if query.Has("since") {
		start, err := time.Parse(time.RFC3339, query.Get("since"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "since 必须是有效的 RFC3339 时间")
			return
		}
		since = &start
	}
	var limit int
	if query.Has("limit") {
		value := query.Get("limit")
		limit, err = strconv.Atoi(value)
		if errors.Is(err, strconv.ErrRange) && limit > 0 &&
			strings.Trim(strings.TrimPrefix(value, "+"), "0123456789") == "" {
			// 正整数溢出时 Atoi 已饱和到最大 int，交给服务按点数上限截断。
			err = nil
		}
		if err != nil || limit < 1 {
			writeError(w, http.StatusBadRequest, "bad_request", "limit 必须是正整数")
			return
		}
	}
	points, err := s.telemetry.Track(r.Context(), r.PathValue("deviceID"), userID, since, limit)
	if err != nil {
		s.writeTelemetryError(w, err)
		return
	}
	res := trackResponse{Points: make([]locationDTO, 0, len(points))}
	for _, p := range points {
		res.Points = append(res.Points, toLocationDTO(p))
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) writeTelemetryError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotOwner):
		writeError(w, http.StatusForbidden, "forbidden", "无权查看该设备")
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "设备暂无可查看的位置")
	default:
		s.log.Error("读取设备遥测失败", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "服务暂时不可用")
	}
}
