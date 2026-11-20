package provision

import (
	"errors"
	"regexp"
	"testing"

	"github.com/bycicle-locating/backend/internal/device"
	"github.com/bycicle-locating/backend/internal/store"
)

func TestCreateDeviceReturnsClaimCodeWithoutReplacingExistingHash(t *testing.T) {
	const deviceID = "BKL-2026-990001"
	const pepper = "provision-test-pepper"
	mem := store.NewMemory()
	code, err := CreateDevice(t.Context(), mem, pepper, deviceID, "BKL1")
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[A-Z2-7]{16}$`).MatchString(code) {
		t.Fatal("声明码必须是 16 位 Base32")
	}
	if duplicate, err := CreateDevice(t.Context(), mem, pepper, deviceID, "other"); !errors.Is(err, store.ErrDeviceExists) || duplicate != "" {
		t.Fatalf("重复登记应拒绝且不输出声明码，实际 %v", err)
	}
	claim, err := mem.ClaimCodeHash(t.Context(), deviceID)
	if err != nil {
		t.Fatal(err)
	}
	hasher, err := device.NewHMACHasher(pepper)
	if err != nil {
		t.Fatal(err)
	}
	if claim.Hash == code || !hasher.Verify(claim.Hash, code) || claim.Claimed {
		t.Fatal("应保留首次登记的声明码哈希")
	}
	d, err := mem.Device(t.Context(), deviceID)
	if err != nil || d.State != store.StateClaimable || d.Model != "BKL1" {
		t.Fatalf("设备登记结果不符：%+v，%v", d, err)
	}
}

func TestCreateDeviceRejectsInvalidID(t *testing.T) {
	mem := store.NewMemory()
	if code, err := CreateDevice(t.Context(), mem, "provision-test-pepper", "invalid-id", "BKL1"); err == nil || code != "" {
		t.Fatal("设备编号不符合协议时应直接拒绝")
	}
}
