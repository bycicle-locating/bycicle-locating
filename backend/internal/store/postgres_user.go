package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func (p *Postgres) CreateUser(ctx context.Context, u User) (User, error) {
	var createdAt *time.Time
	if !u.CreatedAt.IsZero() {
		t := u.CreatedAt
		createdAt = &t
	}
	row := p.pool.QueryRow(ctx, `INSERT INTO users
		(id, email, password_hash, display_name, created_at)
		VALUES (CAST(@id AS uuid), @email, @passwordHash, NULLIF(@displayName, ''), COALESCE(@createdAt, now()))
		RETURNING CAST(id AS text), CAST(email AS text), password_hash,
			COALESCE(display_name, ''), created_at`,
		pgx.NamedArgs{
			"id":           u.ID,
			"email":        u.Email,
			"passwordHash": u.PasswordHash,
			"displayName":  u.DisplayName,
			"createdAt":    createdAt,
		})
	out, err := scanUser(row)
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "users_email_key" {
			return User{}, ErrEmailTaken
		}
		return User{}, err
	}
	return out, nil
}

func (p *Postgres) UserByEmail(ctx context.Context, email string) (User, error) {
	row := p.pool.QueryRow(ctx, `SELECT
		CAST(id AS text), CAST(email AS text), password_hash,
		COALESCE(display_name, ''), created_at
		FROM users WHERE email = @email`, pgx.NamedArgs{"email": email})
	return scanUser(row)
}

func (p *Postgres) UserByID(ctx context.Context, id string) (User, error) {
	row := p.pool.QueryRow(ctx, `SELECT
		CAST(id AS text), CAST(email AS text), password_hash,
		COALESCE(display_name, ''), created_at
		FROM users WHERE id = CAST(@id AS uuid)`, pgx.NamedArgs{"id": id})
	return scanUser(row)
}

func (p *Postgres) UpdateUserDisplayName(ctx context.Context, id, displayName string) (User, error) {
	row := p.pool.QueryRow(ctx, `UPDATE users SET display_name = NULLIF(@displayName, '')
		WHERE id = CAST(@id AS uuid)
		RETURNING CAST(id AS text), CAST(email AS text), password_hash,
			COALESCE(display_name, ''), created_at`,
		pgx.NamedArgs{"id": id, "displayName": displayName})
	return scanUser(row)
}

func (p *Postgres) DevicesByOwner(ctx context.Context, userID string) ([]Device, error) {
	rows, err := p.pool.Query(ctx, `SELECT
		id, model, state, CAST(claimed_by AS text), claimed_at,
		COALESCE(fw_version, ''), COALESCE(label, ''), last_seen_at, config
		FROM devices WHERE claimed_by = CAST(@userID AS uuid)
		ORDER BY claimed_at DESC NULLS LAST`, pgx.NamedArgs{"userID": userID})
	if err != nil {
		return nil, fmt.Errorf("store: 查询车主设备: %w", err)
	}
	defer rows.Close()

	out := make([]Device, 0)
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历车主设备: %w", err)
	}
	return out, nil
}
