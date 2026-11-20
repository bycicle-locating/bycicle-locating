// Package provision 登记设备并生成仅在登记时返回的声明码。
package provision

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"fmt"
	"strings"

	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/protocol"
	"github.com/bycicle-locating/backend/internal/store"
)

func ClaimCode() (string, error) {
	var entropy [10]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", fmt.Errorf("provision: 生成声明码: %w", err)
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(entropy[:]), nil
}

func CreateDevice(ctx context.Context, p store.DeviceProvisioner, pepper, id, model string) (string, error) {
	if !protocol.ValidFactoryDeviceID(id) {
		return "", fmt.Errorf("provision: 设备编号必须符合 BKL-YYYY-NNNNNN")
	}
	model = strings.TrimSpace(model)
	if model == "" {
		return "", fmt.Errorf("provision: 设备型号不能为空")
	}
	hasher, err := device.NewHMACHasher(pepper)
	if err != nil {
		return "", err
	}
	code, err := ClaimCode()
	if err != nil {
		return "", err
	}
	hash, err := hasher.Hash(code)
	if err != nil {
		return "", err
	}
	d := store.Device{ID: id, Model: model, State: store.StateClaimable}
	if err := p.CreateDevice(ctx, d, hash); err != nil {
		return "", fmt.Errorf("provision: 登记设备: %w", err)
	}
	return code, nil
}
