package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

func (p *Postgres) Device(ctx context.Context, deviceID string) (Device, error) {
	row := p.pool.QueryRow(ctx, `SELECT
		id, model, state, CAST(claimed_by AS text), claimed_at,
		COALESCE(fw_version, ''), COALESCE(label, ''), last_seen_at, config
		FROM devices WHERE id = @deviceID`, pgx.NamedArgs{"deviceID": deviceID})
	return scanDevice(row)
}

func (p *Postgres) ClaimCodeHash(ctx context.Context, deviceID string) (ClaimState, error) {
	var hash string
	var claimed bool
	err := p.pool.QueryRow(ctx, `SELECT COALESCE(claim_code_hash, ''), (claimed_by IS NOT NULL)
		FROM devices WHERE id = @deviceID`, pgx.NamedArgs{"deviceID": deviceID}).Scan(&hash, &claimed)
	if errors.Is(err, pgx.ErrNoRows) {
		return ClaimState{}, ErrNotFound
	}
	if err != nil {
		return ClaimState{}, fmt.Errorf("store: 读取声明码: %w", err)
	}
	if hash == "" {
		return ClaimState{}, ErrNotFound
	}
	return ClaimState{Hash: hash, Claimed: claimed}, nil
}

// ownerOf 返回 claimed_by；设备不存在时 ErrNotFound。用于区分绑定/解绑的 0 行结果。
func (p *Postgres) ownerOf(ctx context.Context, deviceID string) (*string, error) {
	var claimed *string
	err := p.pool.QueryRow(ctx, "SELECT CAST(claimed_by AS text) FROM devices WHERE id = @deviceID",
		pgx.NamedArgs{"deviceID": deviceID}).Scan(&claimed)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("store: 读取车主: %w", err)
	}
	return claimed, nil
}
