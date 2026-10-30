// Command server 是后端主进程：同时提供 HTTP API 与 MQTT 消费。
//
// 单进程跑两件事，是因为当前规模下没必要拆；等 MQTT 消费压力上来
// （或需要独立伸缩）时再把 wireIngest 拆成独立 cmd。
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/bycicle-locating/backend/internal/api"
	"github.com/bycicle-locating/backend/internal/config"
	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/ingest"
	"github.com/bycicle-locating/backend/internal/mqtt"
	"github.com/bycicle-locating/backend/internal/protocol"
	"github.com/bycicle-locating/backend/internal/store"
)

// demoDeviceID 是开发环境种子设备。
const demoDeviceID = "BKL-2026-000001"

func main() {
	if err := run(); err != nil {
		slog.Error("服务退出", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	log := newLogger(cfg)
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// TODO(M1): 换成 Postgres 实现；接口已经按 SQL 可实现的方式定义好。
	st := store.NewMemory()
	log.Warn("使用内存存储，重启后数据全部丢失（仅适用于开发）")

	hasher, err := device.NewHMACHasher(cfg.ClaimPepper)
	if err != nil {
		return err
	}
	if cfg.IsDev() && cfg.ClaimPepper == "dev-only-pepper-please-change-me" {
		log.Warn("CLAIM_PEPPER 使用开发默认值，生产环境必须覆盖")
	}

	devices := device.New(st, hasher)
	ing := ingest.New(st, ingest.WithLogger(log))

	if cfg.IsDev() && cfg.DevSeedClaim != "" {
		if err := seedDemoDevice(st, hasher, cfg.DevSeedClaim); err != nil {
			return err
		}
		log.Warn("已注册演示设备（仅开发）",
			"device", demoDeviceID, "claimCode", cfg.DevSeedClaim,
			"hint", "curl -X POST localhost:8080/v1/devices:bind ...")
	}

	bus := mqtt.NewLogBus(log)
	defer func() {
		if cerr := bus.Close(); cerr != nil {
			log.Warn("关闭 MQTT 总线失败", "err", cerr)
		}
	}()
	if err := wireIngest(ctx, bus, ing, log); err != nil {
		return err
	}

	auth, err := buildAuth(cfg, log)
	if err != nil {
		return err
	}

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           api.New(devices, auth, log).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("HTTP 开始监听", "addr", cfg.HTTPAddr, "env", cfg.Env)
		if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("main: HTTP 服务异常: %w", err)
	case <-ctx.Done():
		log.Info("收到退出信号，开始优雅关闭")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("main: 关闭超时: %w", err)
	}
	log.Info("已退出")
	return nil
}

// wireIngest 把 MQTT 消息接到 ingest 服务。
//
// 这里做了三件安全相关的事：主题白名单、载荷校验、以及主题与载荷设备 ID 的一致性检查。
// 三者任一不通过就丢弃并记录——宁可丢一条可疑报文，也不能让它进库。
func wireIngest(ctx context.Context, bus mqtt.Bus, ing *ingest.Service, log *slog.Logger) error {
	handler := func(c context.Context, m mqtt.Message) error {
		topicDevice, _, err := protocol.ParseTopic(m.Topic)
		if err != nil {
			log.Warn("丢弃主题非法的报文", "topic", m.Topic, "err", err)
			return nil
		}
		msg, err := protocol.Decode(m.Payload)
		if err != nil {
			log.Warn("丢弃无效报文", "topic", m.Topic, "err", err)
			return nil
		}
		if msg.DeviceID != topicDevice {
			// 设备凭据只允许写自己的主题；不一致说明账号被复用或有人伪造。
			log.Warn("载荷设备与主题不一致",
				"topic", m.Topic, "payloadDevice", msg.DeviceID)
			return nil
		}

		res, err := ing.Handle(c, msg)
		if err != nil {
			return fmt.Errorf("main: 处理报文: %w", err)
		}
		log.Debug("报文已处理",
			"device", msg.DeviceID, "kind", res.Kind,
			"inserted", res.Inserted, "duplicates", res.Duplicates)
		return nil
	}

	// + 只匹配一层，因此 cmd/ack 需要单独订阅。
	for _, filter := range []string{"v1/device/+/+", "v1/device/+/cmd/ack"} {
		if err := bus.Subscribe(ctx, filter, handler); err != nil {
			return fmt.Errorf("main: 订阅 %s: %w", filter, err)
		}
	}
	return nil
}

func buildAuth(cfg config.Config, log *slog.Logger) (api.Authenticator, error) {
	if !cfg.IsDev() {
		// 生产必须先有真正的鉴权，否则任何人都能绑定设备。
		return nil, errors.New("main: 生产鉴权（JWT）尚未实现，M1 补齐后再启用 APP_ENV=prod")
	}
	log.Warn("使用开发鉴权：请求头 X-Dev-User 即身份，任何人不带凭据也算登录")
	return api.DevAuthenticator{FallbackUser: cfg.DevUserID}, nil
}

func seedDemoDevice(mem *store.Memory, hasher device.Hasher, claim string) error {
	hash, err := hasher.Hash(strings.ToUpper(claim))
	if err != nil {
		return fmt.Errorf("main: 计算演示声明码哈希: %w", err)
	}
	mem.PutDevice(store.Device{ID: demoDeviceID, Model: "BKL1"}, hash)
	return nil
}

func newLogger(cfg config.Config) *slog.Logger {
	var level slog.Level
	switch strings.ToLower(cfg.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}
	return slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
}
