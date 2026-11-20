// Package config 从环境变量加载运行配置。
//
// 刻意不引入 dotenv 库：容器与 systemd 都直接注环境变量，
// 本地开发用 .env.example 里的值手动导出即可（见 README）。
package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// 运行环境。
const (
	EnvDev  = "dev"
	EnvProd = "prod"
)

// devPepper 只在 APP_ENV=dev 且未设置 CLAIM_PEPPER 时使用。
// 生产环境缺失会直接启动失败，避免把开发默认值带上线。
const devPepper = "dev-only-pepper-please-change-me"

// devJWTSecret 只在 APP_ENV=dev 且未配置 DATABASE_URL（纯内存）时使用。
// 配置数据库后必须显式设置 JWT_SECRET：这个默认值在公开仓库里，不能保护持久化实例。
const devJWTSecret = "dev-only-jwt-secret-please-change-me"

// Config 是服务配置。
type Config struct {
	Env          string
	HTTPAddr     string
	LogLevel     string
	ClaimPepper  string
	MQTTURL      string
	MQTTUser     string
	MQTTPass     string
	MQTTCAFile   string
	MQTTClientID string
	DevUserID    string
	// DevSeedClaim 非空时，启动时用该声明码注册一台演示设备，便于本机调绑定接口。
	DevSeedClaim string

	// DatabaseURL 为空且 APP_ENV=dev 时使用内存 store；生产必须设置。
	DatabaseURL string
	JWTSecret   string
	JWTTTL      time.Duration
	JWTIssuer   string
}

// Load 读取环境变量并做最小校验。
func Load() (Config, error) {
	cfg := Config{
		Env:          env("APP_ENV", EnvDev),
		HTTPAddr:     env("HTTP_ADDR", ":8080"),
		LogLevel:     env("LOG_LEVEL", "info"),
		ClaimPepper:  os.Getenv("CLAIM_PEPPER"),
		MQTTURL:      strings.TrimSpace(os.Getenv("MQTT_URL")),
		MQTTUser:     os.Getenv("MQTT_USER"),
		MQTTPass:     os.Getenv("MQTT_PASSWORD"),
		MQTTCAFile:   strings.TrimSpace(os.Getenv("MQTT_CA_FILE")),
		MQTTClientID: env("MQTT_CLIENT_ID", "bkl-backend"),
		DevUserID:    os.Getenv("DEV_USER_ID"),
		DevSeedClaim: os.Getenv("DEV_SEED_CLAIM"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		JWTSecret:    os.Getenv("JWT_SECRET"),
		JWTIssuer:    env("JWT_ISSUER", "bicycle-locating"),
	}

	switch cfg.Env {
	case EnvDev, EnvProd:
	default:
		return Config{}, fmt.Errorf("config: APP_ENV 只能是 dev 或 prod，实际 %q", cfg.Env)
	}

	if cfg.ClaimPepper == "" {
		if cfg.Env == EnvProd {
			return Config{}, fmt.Errorf("config: 生产环境必须设置 CLAIM_PEPPER")
		}
		cfg.ClaimPepper = devPepper
	}
	if len(cfg.ClaimPepper) < 16 {
		return Config{}, fmt.Errorf("config: CLAIM_PEPPER 至少 16 字节")
	}

	if cfg.DatabaseURL == "" && cfg.Env == EnvProd {
		return Config{}, fmt.Errorf("config: 生产环境必须设置 DATABASE_URL")
	}
	if cfg.DatabaseURL != "" && (cfg.JWTSecret == "" || cfg.JWTSecret == devJWTSecret) {
		return Config{}, fmt.Errorf("config: 配置 DATABASE_URL 时必须设置独立的 JWT_SECRET，不能使用开发默认值")
	}
	if cfg.JWTSecret == "" {
		if cfg.Env == EnvProd {
			return Config{}, fmt.Errorf("config: 生产环境必须设置 JWT_SECRET")
		}
		cfg.JWTSecret = devJWTSecret
	}
	if len(cfg.JWTSecret) < 32 {
		return Config{}, fmt.Errorf("config: JWT_SECRET 至少 32 字节")
	}

	ttl := env("JWT_TTL", "24h")
	parsed, err := time.ParseDuration(ttl)
	if err != nil || parsed <= 0 {
		return Config{}, fmt.Errorf("config: JWT_TTL 必须是正的时间长度，实际 %q", ttl)
	}
	cfg.JWTTTL = parsed

	if err := cfg.validateMQTT(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c Config) validateMQTT() error {
	if c.MQTTURL == "" {
		if c.IsDev() {
			return nil
		}
		return fmt.Errorf("config: 生产环境必须设置 MQTT_URL")
	}
	endpoint, err := url.Parse(c.MQTTURL)
	if err != nil || endpoint.User != nil || endpoint.Hostname() == "" ||
		endpoint.Path != "" || endpoint.ForceQuery || endpoint.RawQuery != "" || endpoint.Fragment != "" {
		return fmt.Errorf("config: MQTT_URL 必须是带端口且不含凭据的 Broker 地址")
	}
	port, err := strconv.Atoi(endpoint.Port())
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("config: MQTT_URL 必须包含有效端口")
	}

	switch endpoint.Scheme {
	case "mqtts":
		if c.MQTTUser == "" || c.MQTTPass == "" {
			return fmt.Errorf("config: MQTT TLS 连接必须设置 MQTT_USER 和 MQTT_PASSWORD")
		}
	case "tcp":
		host := endpoint.Hostname()
		local := host == "localhost" || host == "broker" || net.ParseIP(host).IsLoopback()
		if !c.IsDev() || !local || c.MQTTUser != "" || c.MQTTPass != "" || c.MQTTCAFile != "" {
			return fmt.Errorf("config: 明文 MQTT 仅用于无凭据的本地开发 Broker")
		}
	default:
		return fmt.Errorf("config: MQTT_URL 协议必须为 mqtts 或本地开发用 tcp")
	}
	return nil
}

// IsDev 表示当前是否开发环境。
func (c Config) IsDev() bool { return c.Env == EnvDev }

func env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}
