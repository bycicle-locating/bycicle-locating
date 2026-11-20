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
	"github.com/bycicle-locating/backend/internal/auth"
	"github.com/bycicle-locating/backend/internal/config"
	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/ingest"
	"github.com/bycicle-locating/backend/internal/mqtt"
	"github.com/bycicle-locating/backend/internal/protocol"
	"github.com/bycicle-locating/backend/internal/store"
	"github.com/bycicle-locating/backend/internal/telemetry"
	"github.com/bycicle-locating/backend/internal/user"
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

	st, closeStore, err := openStore(ctx, cfg, log)
	if err != nil {
		return err
	}
	defer closeStore()

	hasher, err := device.NewHMACHasher(cfg.ClaimPepper)
	if err != nil {
		return err
	}
	if cfg.IsDev() && cfg.ClaimPepper == "dev-only-pepper-please-change-me" {
		log.Warn("CLAIM_PEPPER 使用开发默认值，生产环境必须覆盖")
	}

	users, err := user.New(st, user.NewArgon2id())
	if err != nil {
		return err
	}
	tokens, err := auth.NewTokens(cfg.JWTSecret, cfg.JWTTTL, cfg.JWTIssuer)
	if err != nil {
		return err
	}
	if cfg.IsDev() && cfg.JWTSecret == "dev-only-jwt-secret-please-change-me" {
		log.Warn("JWT_SECRET 使用开发默认值，仅限纯内存开发模式")
	}

	devices := device.New(st, hasher)
	ing := ingest.New(st, ingest.WithLogger(log))

	if cfg.IsDev() && cfg.DevSeedClaim != "" {
		seeder, ok := st.(store.DeviceSeeder)
		if !ok {
			log.Warn("当前存储不支持演示设备种子，跳过")
		} else if err := seedDemoDevice(ctx, seeder, hasher, cfg.DevSeedClaim); err != nil {
			return err
		} else {
			// 声明码是凭据，不能进日志；需要时从 DEV_SEED_CLAIM 读取。
			log.Warn("已注册演示设备（仅开发）",
				"device", demoDeviceID,
				"hint", "声明码见 DEV_SEED_CLAIM 环境变量")
		}
	}

	bus, err := openBus(ctx, cfg, ing, log)
	if err != nil {
		return err
	}
	defer func() {
		if cerr := bus.Close(); cerr != nil {
			log.Warn("关闭 MQTT 总线失败", "err", cerr)
		}
	}()
	authn, err := buildAuth(cfg, tokens, log)
	if err != nil {
		return err
	}

	httpServer := &http.Server{
		Addr:              cfg.HTTPAddr,
		Handler:           api.New(devices, users, telemetry.New(st), tokens, authn, log).Routes(),
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

func openBus(ctx context.Context, cfg config.Config, ing *ingest.Service, log *slog.Logger) (mqtt.Bus, error) {
	if cfg.MQTTURL == "" {
		log.Warn("未配置 MQTT_URL，当前只启动 HTTP API")
		return mqtt.NewLogBus(log), nil
	}
	bus, err := mqtt.NewPahoBus(ctx, mqtt.BrokerConfig{
		URL: cfg.MQTTURL, Username: cfg.MQTTUser, Password: cfg.MQTTPass,
		CAFile: cfg.MQTTCAFile, ClientID: cfg.MQTTClientID,
	}, log)
	if err != nil {
		return nil, err
	}
	if err := wireIngest(ctx, bus, ing, log); err != nil {
		_ = bus.Close()
		return nil, err
	}
	connectCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	if err := bus.Connect(connectCtx); err != nil {
		_ = bus.Close()
		return nil, err
	}
	return bus, nil
}

// wireIngest 把 MQTT 消息接到 ingest 服务。
//
// 主题、载荷或两者不匹配时直接丢弃；持久化错误交给总线重试。
func wireIngest(ctx context.Context, bus mqtt.Bus, ing *ingest.Service, log *slog.Logger) error {
	handler := func(c context.Context, m mqtt.Message) error {
		topicDevice, topicKind, err := protocol.ParseTopic(m.Topic)
		if err != nil {
			log.Warn("丢弃主题非法的报文", "topic", m.Topic, "err", err)
			return nil
		}
		msg, err := protocol.Decode(m.Payload)
		if err != nil {
			log.Warn("丢弃无效报文", "topic", m.Topic, "err", err)
			return nil
		}
		if msg.DeviceID != topicDevice || msg.Kind != topicKind {
			log.Warn("载荷与主题不一致",
				"topic", m.Topic, "payloadDevice", msg.DeviceID, "payloadKind", msg.Kind)
			return nil
		}

		res, err := ing.Handle(c, msg)
		if errors.Is(err, store.ErrNotFound) {
			log.Warn("丢弃未注册设备的报文", "topic", m.Topic)
			return nil
		}
		if errors.Is(err, store.ErrInvalidUplink) {
			log.Warn("丢弃无法持久化的报文", "topic", m.Topic, "err", err)
			return nil
		}
		if err != nil {
			return fmt.Errorf("main: 处理报文: %w", err)
		}
		log.Debug("报文已处理",
			"device", msg.DeviceID, "kind", res.Kind,
			"inserted", res.Inserted, "duplicates", res.Duplicates)
		return nil
	}

	for _, filter := range []string{"v1/device/+/telemetry", "v1/device/+/event", "v1/device/+/status", "v1/device/+/cmd/ack"} {
		if err := bus.Subscribe(ctx, filter, handler); err != nil {
			return fmt.Errorf("main: 订阅 %s: %w", filter, err)
		}
	}
	return nil
}

func openStore(ctx context.Context, cfg config.Config, log *slog.Logger) (store.Store, func(), error) {
	if cfg.DatabaseURL != "" {
		pg, err := store.NewPostgres(ctx, cfg.DatabaseURL)
		if err != nil {
			return nil, nil, err
		}
		if err := pg.CheckSchema(ctx); err != nil {
			pg.Close()
			return nil, nil, err
		}
		log.Info("使用 Postgres 存储")
		return pg, pg.Close, nil
	}
	if !cfg.IsDev() {
		return nil, nil, errors.New("main: 生产环境必须配置 DATABASE_URL")
	}
	log.Warn("使用内存存储，重启后数据全部丢失（仅适用于开发）")
	return store.NewMemory(), func() {}, nil
}

func buildAuth(cfg config.Config, tokens *auth.Tokens, log *slog.Logger) (api.Authenticator, error) {
	jwtAuth := api.JWTAuthenticator{Tokens: tokens}
	if cfg.IsDev() && cfg.DatabaseURL == "" {
		log.Warn("开发环境允许 X-Dev-User 回退；配置 DATABASE_URL 后只认 JWT")
		return api.ChainAuthenticator{
			JWT: jwtAuth,
			Dev: api.DevAuthenticator{FallbackUser: cfg.DevUserID},
		}, nil
	}
	if cfg.IsDev() {
		log.Warn("已配置 DATABASE_URL，开发身份回退关闭，只认 JWT")
	}
	return jwtAuth, nil
}

func seedDemoDevice(ctx context.Context, seeder store.DeviceSeeder, hasher device.Hasher, claim string) error {
	hash, err := hasher.Hash(strings.ToUpper(claim))
	if err != nil {
		return fmt.Errorf("main: 计算演示声明码哈希: %w", err)
	}
	if err := seeder.SeedDevice(ctx, store.Device{ID: demoDeviceID, Model: "BKL1"}, hash); err != nil {
		return fmt.Errorf("main: 注册演示设备: %w", err)
	}
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
