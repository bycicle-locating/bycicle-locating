package config

import (
	"strings"
	"testing"
)

func TestLoadDevDefaults(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("CLAIM_PEPPER", "")
	t.Setenv("DATABASE_URL", "")
	t.Setenv("JWT_SECRET", "")
	t.Setenv("MQTT_URL", "")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.DatabaseURL != "" || cfg.JWTSecret == "" || cfg.JWTTTL <= 0 {
		t.Fatalf("dev 默认值不符：%+v", cfg)
	}
	if cfg.MQTTURL != "" {
		t.Fatalf("未配置时不应尝试连接 MQTT，实际 %q", cfg.MQTTURL)
	}
}

func TestLoadRejectsDevJWTSecretWithDatabase(t *testing.T) {
	t.Setenv("APP_ENV", "dev")
	t.Setenv("CLAIM_PEPPER", strings.Repeat("p", 16))
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SECRET", "")
	if _, err := Load(); err == nil {
		t.Fatal("配置 DATABASE_URL 但缺少 JWT_SECRET 应拒绝启动")
	}
	t.Setenv("JWT_SECRET", devJWTSecret)
	if _, err := Load(); err == nil {
		t.Fatal("配置 DATABASE_URL 但使用开发默认 JWT_SECRET 应拒绝启动")
	}
	t.Setenv("JWT_SECRET", strings.Repeat("s", 32))
	if _, err := Load(); err != nil {
		t.Fatalf("独立 JWT_SECRET 应通过：%v", err)
	}
}

func TestLoadProdRequiresDBAndJWT(t *testing.T) {
	t.Setenv("APP_ENV", "prod")
	t.Setenv("CLAIM_PEPPER", strings.Repeat("p", 16))
	t.Setenv("DATABASE_URL", "")
	t.Setenv("JWT_SECRET", "")
	t.Setenv("MQTT_URL", "mqtts://broker.example:8883")
	t.Setenv("MQTT_USER", "backend")
	t.Setenv("MQTT_PASSWORD", "test-only-password")
	if _, err := Load(); err == nil {
		t.Fatal("prod 缺 DATABASE_URL/JWT_SECRET 应拒绝启动")
	}
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SECRET", strings.Repeat("s", 32))
	if _, err := Load(); err != nil {
		t.Fatalf("prod 配置齐全仍失败：%v", err)
	}
}

func TestLoadProdRequiresAuthenticatedTLSMQTT(t *testing.T) {
	t.Setenv("APP_ENV", "prod")
	t.Setenv("CLAIM_PEPPER", strings.Repeat("p", 16))
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SECRET", strings.Repeat("s", 32))

	for _, test := range []struct {
		name, url, user, password string
	}{
		{name: "没有 Broker"},
		{name: "明文", url: "tcp://broker.example:1883", user: "backend", password: "test-only-password"},
		{name: "没有凭据", url: "mqtts://broker.example:8883"},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("MQTT_URL", test.url)
			t.Setenv("MQTT_USER", test.user)
			t.Setenv("MQTT_PASSWORD", test.password)
			if _, err := Load(); err == nil {
				t.Fatal("生产环境应拒绝该 MQTT 配置")
			}
		})
	}
}
