package store

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

type rowScanner interface {
	Scan(dest ...any) error
}

func scanDevice(row rowScanner) (Device, error) {
	var d Device
	var claimed *string
	var config []byte
	err := row.Scan(&d.ID, &d.Model, &d.State, &claimed, &d.ClaimedAt,
		&d.FWVersion, &d.Label, &d.LastSeenAt, &config)
	if errors.Is(err, pgx.ErrNoRows) {
		return Device{}, ErrNotFound
	}
	if err != nil {
		return Device{}, fmt.Errorf("store: 读取设备: %w", err)
	}
	d.ClaimedBy = claimed
	if len(config) > 0 {
		if err := json.Unmarshal(config, &d.Config); err != nil {
			return Device{}, fmt.Errorf("store: 解析设备配置: %w", err)
		}
	}
	if d.Config == nil {
		d.Config = map[string]any{}
	}
	return d, nil
}

func scanUser(row rowScanner) (User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Email, &u.PasswordHash, &u.DisplayName, &u.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return User{}, ErrNotFound
	}
	if err != nil {
		return User{}, fmt.Errorf("store: 读取用户: %w", err)
	}
	return u, nil
}
