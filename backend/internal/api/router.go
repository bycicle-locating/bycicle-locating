// Package api 是 HTTP 边界：只做鉴权、解码、调用服务、编码响应。
// 任何业务判断都不应该出现在 handler 里。
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/store"
)

// maxBodyBytes 限制请求体，防止畸形大包占用内存。
const maxBodyBytes = 8 << 10

// ErrUnauthenticated 表示请求没有可识别的身份。
var ErrUnauthenticated = errors.New("api: 未登录")

// Authenticator 从请求中解析用户 ID。真实实现是 JWT（M1），
// 当前提供仅开发可用的 DevAuthenticator。
type Authenticator interface {
	User(ctx context.Context, r *http.Request) (userID string, err error)
}

// DevAuthenticator 直接信任请求头，**只能用于本地开发**。
//
// FallbackUser 非空时，没有请求头的请求也视为该用户，便于用 curl 冒烟测试。
type DevAuthenticator struct {
	FallbackUser string
}

// User 实现 Authenticator。
func (a DevAuthenticator) User(_ context.Context, r *http.Request) (string, error) {
	if u := r.Header.Get("X-Dev-User"); u != "" {
		return u, nil
	}
	if a.FallbackUser != "" {
		return a.FallbackUser, nil
	}
	return "", ErrUnauthenticated
}

// Server 持有 HTTP 依赖，本身无状态。
type Server struct {
	devices *device.Service
	auth    Authenticator
	log     *slog.Logger
}

// New 构造 HTTP 服务。
func New(devices *device.Service, auth Authenticator, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	return &Server{devices: devices, auth: auth, log: log}
}

// Routes 返回挂好中间件的路由表。
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("POST /v1/devices:bind", s.handleBind)
	mux.HandleFunc("DELETE /v1/devices/{deviceID}/binding", s.handleUnbind)
	mux.HandleFunc("GET /v1/devices/{deviceID}", s.handleGetDevice)
	return s.withRecovery(s.withLogging(mux))
}

// --- handlers ---

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type bindRequest struct {
	DeviceID  string `json:"deviceId"`
	ClaimCode string `json:"claimCode"`
	Label     string `json:"label,omitempty"`
}

func (s *Server) handleBind(w http.ResponseWriter, r *http.Request) {
	userID, err := s.auth.User(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "请先登录")
		return
	}

	var req bindRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体格式错误")
		return
	}
	if req.DeviceID == "" || req.ClaimCode == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "deviceId 与 claimCode 必填")
		return
	}

	d, err := s.devices.Bind(r.Context(), req.DeviceID, req.ClaimCode, userID, req.Label)
	if err != nil {
		s.writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toDeviceDTO(d))
}

func (s *Server) handleUnbind(w http.ResponseWriter, r *http.Request) {
	userID, err := s.auth.User(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "请先登录")
		return
	}
	deviceID := r.PathValue("deviceID")
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "缺少设备 ID")
		return
	}
	if err := s.devices.Unbind(r.Context(), deviceID, userID); err != nil {
		s.writeDomainError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetDevice(w http.ResponseWriter, r *http.Request) {
	userID, err := s.auth.User(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthenticated", "请先登录")
		return
	}
	d, err := s.devices.Get(r.Context(), r.PathValue("deviceID"))
	if err != nil {
		s.writeDomainError(w, err)
		return
	}
	// 只允许车主查看；资料页需要非车主也能看到"该设备已被绑定"，
	// 但那属于另一个只返回最小信息的接口，M1 再补。
	if d.ClaimedBy == nil || *d.ClaimedBy != userID {
		writeError(w, http.StatusForbidden, "forbidden", "无权查看该设备")
		return
	}
	writeJSON(w, http.StatusOK, toDeviceDTO(d))
}

// --- 响应辅助 ---

type deviceDTO struct {
	ID         string     `json:"id"`
	Model      string     `json:"model"`
	State      string     `json:"state"`
	Bound      bool       `json:"bound"`
	Label      string     `json:"label,omitempty"`
	Firmware   string     `json:"firmware,omitempty"`
	ClaimedAt  *time.Time `json:"claimedAt,omitempty"`
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
}

// toDeviceDTO 有意不包含声明码哈希与车主 ID：前者是密钥，后者会泄露他人身份。
func toDeviceDTO(d store.Device) deviceDTO {
	return deviceDTO{
		ID:         d.ID,
		Model:      d.Model,
		State:      d.State,
		Bound:      d.ClaimedBy != nil,
		Label:      d.Label,
		Firmware:   d.FWVersion,
		ClaimedAt:  d.ClaimedAt,
		LastSeenAt: d.LastSeenAt,
	}
}

func (s *Server) writeDomainError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, device.ErrInvalidClaim):
		// 设备不存在与声明码错误返回同一个响应，避免枚举设备。
		writeError(w, http.StatusForbidden, "invalid_claim", "标签无效或已被使用")
	case errors.Is(err, device.ErrAlreadyBound):
		writeError(w, http.StatusConflict, "already_bound", "该设备已被绑定")
	case errors.Is(err, device.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", "无权操作该设备")
	case errors.Is(err, device.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "设备不存在")
	default:
		s.log.Error("处理请求失败", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "服务暂时不可用")
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	return dec.Decode(dst)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Default().Warn("写响应失败", "err", err)
	}
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}

// --- 中间件 ---

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (s *Server) withLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		// 不记录 query 与请求体：绑定请求里带声明码，属于敏感数据。
		s.log.Info("http",
			"method", r.Method, "path", r.URL.Path,
			"status", rec.status, "ms", time.Since(start).Milliseconds())
	})
}

func (s *Server) withRecovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.log.Error("panic 恢复", "panic", rec, "path", r.URL.Path)
				writeError(w, http.StatusInternalServerError, "internal", "服务暂时不可用")
			}
		}()
		next.ServeHTTP(w, r)
	})
}
