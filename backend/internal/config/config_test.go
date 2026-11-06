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
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.DatabaseURL != "" || cfg.JWTSecret == "" || cfg.JWTTTL <= 0 {
		t.Fatalf("dev 默认值不符：%+v", cfg)
	}
}

func TestLoadProdRequiresDBAndJWT(t *testing.T) {
	t.Setenv("APP_ENV", "prod")
	t.Setenv("CLAIM_PEPPER", strings.Repeat("p", 16))
	t.Setenv("DATABASE_URL", "")
	t.Setenv("JWT_SECRET", "")
	if _, err := Load(); err == nil {
		t.Fatal("prod 缺 DATABASE_URL/JWT_SECRET 应拒绝启动")
	}
	t.Setenv("DATABASE_URL", "postgres://example")
	t.Setenv("JWT_SECRET", strings.Repeat("s", 32))
	if _, err := Load(); err != nil {
		t.Fatalf("prod 配置齐全仍失败：%v", err)
	}
}
