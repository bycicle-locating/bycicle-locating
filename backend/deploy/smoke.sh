#!/usr/bin/env bash
# 对一个运行中的部署栈执行 HTTP 全链路冒烟测试：客户端 → nginx → backend → store。
#
# 用法：
#   BASE_URL=http://127.0.0.1:8080 \
#   DEV_USER_ID=... CLAIM_CODE=... ./deploy/smoke.sh
#
# 依赖：curl。脚本会先清理演示设备的旧绑定，因此可以重复执行。
set -euo pipefail

BASE_URL=${BASE_URL:-http://127.0.0.1:32525}
DEVICE_ID=${DEVICE_ID:-BKL-2026-000001}
OTHER_USER_ID=${OTHER_USER_ID:-22222222-2222-2222-2222-222222222222}
# 非法声明码只用于验证 403 路径，不是任何可用的凭据。
WRONG_CLAIM=${WRONG_CLAIM:-AAAAAAAAAAAAAAAA}
DEV_USER_ID=${DEV_USER_ID:?请设置 DEV_USER_ID}
CLAIM_CODE=${CLAIM_CODE:?请设置 CLAIM_CODE}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 可选：Cloudflare Access 启用的服务令牌。App/固件后续走 JWT，不依赖这里。
access_args=()
if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
  access_args=(
    -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID"
    -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET"
  )
fi

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

# request METHOD PATH [curl args...] → 设置 STATUS / BODY
request() {
  local method=$1 path=$2
  shift 2
  if ! STATUS=$(curl -sS --max-time 30 -o "$tmp/body" -w '%{http_code}' -X "$method" "${access_args[@]}" "$BASE_URL$path" "$@"); then
    fail "$method $path 请求失败"
    STATUS=000
    BODY=""
    return 0
  fi
  BODY=$(cat "$tmp/body")
}

expect_status() {
  local want=$1 label=$2
  if [ "$STATUS" = "$want" ]; then
    pass "$label"
  else
    fail "$label：期望 $want，实际 $STATUS，响应 $BODY"
  fi
}

expect_body() {
  local needle=$1 label=$2
  case "$BODY" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label：响应缺少 $needle（$BODY）" ;;
  esac
}

echo "== 全链路冒烟：$BASE_URL =="

request GET /healthz
expect_status 200 "healthz 返回 200"
expect_body '"status":"ok"' "healthz 响应体"

if [ "${EXPECT_UNAUTHENTICATED:-0}" = "1" ]; then
  request GET "/v1/devices/$DEVICE_ID"
  expect_status 401 "无身份请求被拒绝"
  expect_body '"unauthenticated"' "无身份错误码"
fi

# 先解绑，保证脚本可重复执行。未绑定/非车主都返回 403，404 表示设备不存在。
request DELETE "/v1/devices/$DEVICE_ID/binding" -H "X-Dev-User: $DEV_USER_ID"
case "$STATUS" in
  204|403|404) pass "前置清理（$STATUS）" ;;
  *) fail "前置清理：意外状态 $STATUS（$BODY）" ;;
esac

request POST /v1/devices:bind \
  -H 'Content-Type: application/json' \
  -H "X-Dev-User: $DEV_USER_ID" \
  --data "{\"deviceId\":\"$DEVICE_ID\",\"claimCode\":\"$CLAIM_CODE\",\"label\":\"e2e\"}"
expect_status 200 "绑定成功"
expect_body '"bound":true' "绑定响应"

request POST /v1/devices:bind \
  -H 'Content-Type: application/json' \
  -H "X-Dev-User: $DEV_USER_ID" \
  --data "{\"deviceId\":\"$DEVICE_ID\",\"claimCode\":\"$CLAIM_CODE\"}"
expect_status 409 "重复绑定被拒绝"
expect_body '"already_bound"' "重复绑定错误码"

request POST /v1/devices:bind \
  -H 'Content-Type: application/json' \
  -H "X-Dev-User: $DEV_USER_ID" \
  --data "{\"deviceId\":\"$DEVICE_ID\",\"claimCode\":\"$WRONG_CLAIM\"}"
expect_status 403 "错误声明码被拒绝"
expect_body '"invalid_claim"' "错误声明码错误码"

request GET "/v1/devices/$DEVICE_ID" -H "X-Dev-User: $DEV_USER_ID"
expect_status 200 "车主读取设备"
expect_body '"bound":true' "设备已绑定状态"

request GET "/v1/devices/$DEVICE_ID" -H "X-Dev-User: $OTHER_USER_ID"
expect_status 403 "非车主读取设备被拒绝"
expect_body '"forbidden"' "非车主读取错误码"

request DELETE "/v1/devices/$DEVICE_ID/binding" -H "X-Dev-User: $OTHER_USER_ID"
expect_status 403 "非车主要求解绑被拒绝"
expect_body '"forbidden"' "非车主解绑错误码"

request DELETE "/v1/devices/$DEVICE_ID/binding" -H "X-Dev-User: $DEV_USER_ID"
expect_status 204 "车主解绑成功"

request GET "/v1/devices/$DEVICE_ID" -H "X-Dev-User: $DEV_USER_ID"
expect_status 403 "解绑后车主不可见"
expect_body '"forbidden"' "解绑后读取错误码"

if [ "$failures" -ne 0 ]; then
  echo "== 失败 $failures 项 ==" >&2
  exit 1
fi
echo "== 全部通过 =="
