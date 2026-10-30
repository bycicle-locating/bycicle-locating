package device

import (
	"context"
	"errors"
	"testing"

	"github.com/bycicle-locating/backend/internal/store"
)

const (
	testDeviceID = "BKL-2026-000001"
	testClaim    = "7QK2M5XJ4TZP6RWN"
	testUser     = "11111111-1111-1111-1111-111111111111"
	testPepper   = "test-pepper-at-least-16-bytes"
)

func newService(t *testing.T) (*Service, *store.Memory, *HMACHasher) {
	t.Helper()
	hasher, err := NewHMACHasher(testPepper)
	if err != nil {
		t.Fatalf("构造 hasher 失败: %v", err)
	}
	mem := store.NewMemory()
	mem.PutDevice(store.Device{ID: testDeviceID, Model: "BKL1"}, mustHash(t, hasher, testClaim))
	return New(mem, hasher), mem, hasher
}

func mustHash(t *testing.T, h Hasher, secret string) string {
	t.Helper()
	hash, err := h.Hash(secret)
	if err != nil {
		t.Fatalf("计算哈希失败: %v", err)
	}
	return hash
}

func TestBindSuccess(t *testing.T) {
	svc, _, _ := newService(t)

	d, err := svc.Bind(context.Background(), testDeviceID, testClaim, testUser, "通勤车")
	if err != nil {
		t.Fatalf("绑定应成功，实际 %v", err)
	}
	if d.ClaimedBy == nil || *d.ClaimedBy != testUser {
		t.Fatalf("车主未写入，实际 %+v", d.ClaimedBy)
	}
	if d.State != store.StateClaimed {
		t.Fatalf("期望状态 CLAIMED，实际 %q", d.State)
	}
	if d.Label != "通勤车" {
		t.Fatalf("备注未保存（中文是否被截断？），实际 %q", d.Label)
	}
}

func TestBindIsCaseInsensitive(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, "7qk2m5xj4tzp6rwn", testUser, ""); err != nil {
		t.Fatalf("小写声明码应被接受，实际 %v", err)
	}
}

func TestBindTwiceReportsAlreadyBound(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, testUser, ""); err != nil {
		t.Fatalf("首次绑定失败: %v", err)
	}

	// 换一个用户再绑同一台设备，必须是 already_bound 而不是 invalid_claim，
	// 否则 App 无法给出"已被绑定，请联系客服"的提示。
	other := "22222222-2222-2222-2222-222222222222"
	_, err := svc.Bind(context.Background(), testDeviceID, testClaim, other, "")
	if !errors.Is(err, ErrAlreadyBound) {
		t.Fatalf("期望 ErrAlreadyBound，实际 %v", err)
	}
}

func TestBoundDeviceWithWrongClaimDoesNotRevealState(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, testUser, ""); err != nil {
		t.Fatalf("首次绑定失败: %v", err)
	}

	// 已绑定的设备 + 错误声明码：必须仍然是 invalid_claim。
	// 若这里返回 already_bound，任何知道 deviceId 的人都能探出该车是否已注册。
	_, err := svc.Bind(context.Background(), testDeviceID, "AAAAAAAAAAAAAAAA", testUser, "")
	if !errors.Is(err, ErrInvalidClaim) {
		t.Fatalf("已绑定设备配错误声明码应返回 ErrInvalidClaim，实际 %v", err)
	}
}

func TestBindWrongClaimAndUnknownDeviceAreIndistinguishable(t *testing.T) {
	svc, _, _ := newService(t)

	// 声明码错误
	_, wrong := svc.Bind(context.Background(), testDeviceID, "AAAAAAAAAAAAAAAA", testUser, "")
	// 设备根本不存在
	_, unknown := svc.Bind(context.Background(), "BKL-2026-999999", testClaim, testUser, "")

	if !errors.Is(wrong, ErrInvalidClaim) {
		t.Fatalf("错误声明码期望 ErrInvalidClaim，实际 %v", wrong)
	}
	if !errors.Is(unknown, ErrInvalidClaim) {
		t.Fatalf("未知设备期望 ErrInvalidClaim，实际 %v", unknown)
	}
}

func TestBindRejectsMalformedClaim(t *testing.T) {
	svc, _, _ := newService(t)
	// 含 Base32 字母表之外的 0/1/8/9，应被格式校验直接拒绝，不打到存储层
	if _, err := svc.Bind(context.Background(), testDeviceID, "0189ABCDEFGHJKLM", testUser, ""); !errors.Is(err, ErrInvalidClaim) {
		t.Fatalf("期望 ErrInvalidClaim，实际 %v", err)
	}
}

func TestRebindAfterUnbindUsesSameClaimCode(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, testUser, ""); err != nil {
		t.Fatalf("首次绑定失败: %v", err)
	}
	if err := svc.Unbind(context.Background(), testDeviceID, testUser); err != nil {
		t.Fatalf("解绑失败: %v", err)
	}

	// 解绑后原声明码恢复可用：NFC 标签上锁后无法改写，
	// 二手转让只能靠原标签重新绑定。这是有意行为，不是回归。
	newOwner := "33333333-3333-3333-3333-333333333333"
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, newOwner, "二手"); err != nil {
		t.Fatalf("解绑后应可用原声明码重新绑定，实际 %v", err)
	}

	d, err := svc.Get(context.Background(), testDeviceID)
	if err != nil {
		t.Fatalf("读取设备失败: %v", err)
	}
	if d.ClaimedBy == nil || *d.ClaimedBy != newOwner {
		t.Fatalf("车主应更新为新用户，实际 %v", d.ClaimedBy)
	}
}

func TestBindRequiresUser(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, "", ""); !errors.Is(err, ErrForbidden) {
		t.Fatalf("期望 ErrForbidden，实际 %v", err)
	}
}

func TestUnbindOnlyByOwner(t *testing.T) {
	svc, _, _ := newService(t)
	if _, err := svc.Bind(context.Background(), testDeviceID, testClaim, testUser, ""); err != nil {
		t.Fatalf("绑定失败: %v", err)
	}

	// 非车主不能解绑：这是防盗的关键，丢车后偷车者无法把车移出监控。
	if err := svc.Unbind(context.Background(), testDeviceID, "99999999-9999-9999-9999-999999999999"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("非车主解绑期望 ErrForbidden，实际 %v", err)
	}
	if err := svc.Unbind(context.Background(), testDeviceID, testUser); err != nil {
		t.Fatalf("车主解绑应成功，实际 %v", err)
	}

	d, err := svc.Get(context.Background(), testDeviceID)
	if err != nil {
		t.Fatalf("读取设备失败: %v", err)
	}
	if d.ClaimedBy != nil {
		t.Fatalf("解绑后 claimed_by 应为空，实际 %v", *d.ClaimedBy)
	}
}

func TestHMACHasher(t *testing.T) {
	h, err := NewHMACHasher(testPepper)
	if err != nil {
		t.Fatalf("构造失败: %v", err)
	}
	hash, err := h.Hash(testClaim)
	if err != nil {
		t.Fatalf("哈希失败: %v", err)
	}
	if !h.Verify(hash, testClaim) {
		t.Fatal("正确声明码应校验通过")
	}
	if h.Verify(hash, "AAAAAAAAAAAAAAAA") {
		t.Fatal("错误声明码不应通过")
	}
	if h.Verify("", testClaim) {
		t.Fatal("空哈希不应通过")
	}

	// 不同 pepper 必须产生不同哈希，否则去掉 pepper 也能通过
	other, err := NewHMACHasher("another-pepper-16-bytes-long")
	if err != nil {
		t.Fatalf("构造第二个 hasher 失败: %v", err)
	}
	if other.Verify(hash, testClaim) {
		t.Fatal("换了 pepper 之后旧哈希不应通过")
	}

	if _, err := NewHMACHasher("short"); err == nil {
		t.Fatal("过短的 pepper 应被拒绝")
	}
}
