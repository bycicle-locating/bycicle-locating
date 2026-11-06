package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

func (p *Postgres) BindDevice(ctx context.Context, deviceID, userID, label string) (Device, error) {
	row := p.pool.QueryRow(ctx, `UPDATE devices SET
		claimed_by = CAST(@userID AS uuid),
		claimed_at = now(),
		state = 'CLAIMED',
		label = CASE WHEN @label = '' THEN label ELSE @label END
		WHERE id = @deviceID AND claimed_by IS NULL
		RETURNING id, model, state, CAST(claimed_by AS text), claimed_at,
			COALESCE(fw_version, ''), COALESCE(label, ''), last_seen_at, config`,
		pgx.NamedArgs{"deviceID": deviceID, "userID": userID, "label": label})
	d, err := scanDevice(row)
	if errors.Is(err, ErrNotFound) {
		if _, err := p.ownerOf(ctx, deviceID); errors.Is(err, ErrNotFound) {
			return Device{}, ErrNotFound
		} else if err != nil {
			return Device{}, err
		}
		return Device{}, ErrAlreadyBound
	}
	if err != nil {
		return Device{}, err
	}
	return d, nil
}

func (p *Postgres) UnbindDevice(ctx context.Context, deviceID, userID string) error {
	var id string
	err := p.pool.QueryRow(ctx, `UPDATE devices SET
		claimed_by = NULL, state = 'CLAIMABLE'
		WHERE id = @deviceID AND claimed_by = CAST(@userID AS uuid)
		RETURNING id`,
		pgx.NamedArgs{"deviceID": deviceID, "userID": userID}).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		owner, err := p.ownerOf(ctx, deviceID)
		if errors.Is(err, ErrNotFound) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if owner == nil || *owner != userID {
			return ErrNotBound
		}
		// 更新条件与 ownerOf 结果矛盾时按未绑定处理，避免把内部状态泄露给调用方。
		return ErrNotBound
	}
	if err != nil {
		return fmt.Errorf("store: 解绑设备: %w", err)
	}
	return nil
}

func (p *Postgres) TouchLastSeen(ctx context.Context, deviceID string, at time.Time) error {
	if _, err := p.pool.Exec(ctx, "UPDATE devices SET last_seen_at = @at WHERE id = @deviceID",
		pgx.NamedArgs{"deviceID": deviceID, "at": at}); err != nil {
		return fmt.Errorf("store: 更新活跃时间: %w", err)
	}
	return nil
}

func (p *Postgres) SeedDevice(ctx context.Context, d Device, claimCodeHash string) error {
	state := d.State
	if state == "" {
		state = StateClaimable
	}
	var hash any
	if claimCodeHash != "" {
		hash = claimCodeHash
	}
	if _, err := p.pool.Exec(ctx, `INSERT INTO devices (id, model, state, claim_code_hash)
		VALUES (@id, @model, @state, @hash) ON CONFLICT (id) DO NOTHING`,
		pgx.NamedArgs{"id": d.ID, "model": d.Model, "state": state, "hash": hash}); err != nil {
		return fmt.Errorf("store: 注册演示设备: %w", err)
	}
	return nil
}
