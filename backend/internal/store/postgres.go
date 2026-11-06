package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const schemaVersion = "0001_init.sql"

// Postgres 是持久化实现。所有 SQL 都留在本包内，接口不暴露 pgx 类型。
type Postgres struct {
	pool *pgxpool.Pool
}

// NewPostgres 连接数据库并验证可达性。schema 由 deploy/migrate 单独执行。
func NewPostgres(ctx context.Context, dsn string) (*Postgres, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		// 不包装原始错误：pgx/url 的解析错误可能回显含密码的完整 DSN。
		return nil, errors.New("store: DATABASE_URL 格式无效")
	}
	cfg.MaxConns = 10
	cfg.MinConns = 1
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("store: 连接 Postgres: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: Ping Postgres: %w", err)
	}
	return &Postgres{pool: pool}, nil
}

// Close 关闭连接池。
func (p *Postgres) Close() { p.pool.Close() }

// CheckSchema 确认迁移已执行且关键表存在，避免带着空库启动。
func (p *Postgres) CheckSchema(ctx context.Context) error {
	var versionOK, usersOK, devicesOK, bindingsOK, telemetryOK, eventsOK, statusOK bool
	err := p.pool.QueryRow(ctx, `SELECT
		EXISTS (SELECT 1 FROM schema_migrations WHERE version = @version),
		to_regclass('public.users') IS NOT NULL,
		to_regclass('public.devices') IS NOT NULL,
		to_regclass('public.device_bindings') IS NOT NULL,
		to_regclass('public.telemetry_points') IS NOT NULL,
		to_regclass('public.events') IS NOT NULL,
		to_regclass('public.device_status') IS NOT NULL`,
		pgx.NamedArgs{"version": schemaVersion}).
		Scan(&versionOK, &usersOK, &devicesOK, &bindingsOK, &telemetryOK, &eventsOK, &statusOK)
	if err != nil {
		return fmt.Errorf("store: 检查 schema（先运行 docker compose --profile deps run --rm migrate）: %w", err)
	}
	if !versionOK || !usersOK || !devicesOK || !bindingsOK || !telemetryOK || !eventsOK || !statusOK {
		return errors.New("store: schema 未初始化或缺少表（先运行 docker compose --profile deps run --rm migrate）")
	}
	return nil
}
