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
		return nil, fmt.Errorf("store: 解析 DATABASE_URL: %w", err)
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

// CheckSchema 确认迁移已执行，避免带着空库启动。
func (p *Postgres) CheckSchema(ctx context.Context) error {
	var ok bool
	err := p.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = @version)`,
		pgx.NamedArgs{"version": schemaVersion}).Scan(&ok)
	if err != nil {
		return fmt.Errorf("store: 检查 schema（先运行 docker compose --profile deps run --rm migrate）: %w", err)
	}
	if !ok {
		return errors.New("store: schema 未初始化（先运行 docker compose --profile deps run --rm migrate）")
	}
	return nil
}
