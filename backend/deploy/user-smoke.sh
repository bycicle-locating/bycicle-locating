#!/usr/bin/env bash
# 用户 API 冒烟：注册/登录/资料/我的设备，可选绑定一台演示设备。
#
# 用法：
#   BASE_URL=https://bycicle-locating.top \
#   CLAIM_CODE=... DEVICE_ID=BKL-2026-000001 \
#   bash deploy/user-smoke.sh
#
# 依赖：curl、openssl。脚本会创建随机测试账号，不打印密码或 token。
set -euo pipefail

BASE_URL=${BASE_URL:-http://127.0.0.1:32525}
DEVICE_ID=${DEVICE_ID:-BKL-2026-000001}
CLAIM_CODE=${CLAIM_CODE:-}
EMAIL=${SMOKE_EMAIL:-"smoke-$(openssl rand -hex 8)@example.com"}
PASSWORD=${SMOKE_PASSWORD:-"$(openssl rand -hex 16)"}
TOKEN=""

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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

request() {
  local method=$1 path=$2
  shift 2
  local auth=()
  if [ -n "$TOKEN" ]; then
    auth=(-H "Authorization: Bearer $TOKEN")
  fi
  if ! STATUS=$(curl -sS --max-time 30 -o "$tmp/body" -w '%{http_code}' \
    -X "$method" -H 'Content-Type: application/json' "${access_args[@]}" "${auth[@]}" \
    "$BASE_URL$path" "$@"); then
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

extract_token() {
  printf '%s' "$BODY" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}

echo "== 用户 API 冒烟：$BASE_URL =="

request GET /healthz
expect_status 200 "healthz 返回 200"
expect_body '"status":"ok"' "healthz 响应体"

request POST /v1/auth/register \
  --data "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"displayName\":\"smoke\"}"
case "$STATUS" in
  201)
    pass "注册成功"
    TOKEN=$(extract_token)
    ;;
  409)
    pass "邮箱已存在，改走登录"
    request POST /v1/auth/login \
      --data "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}"
    expect_status 200 "登录成功"
    TOKEN=$(extract_token)
    ;;
  *)
    fail "注册：意外状态 $STATUS（$BODY）"
    ;;
esac
if [ -z "$TOKEN" ]; then
  fail "未取得 token"
  echo "== 失败 $failures 项 ==" >&2
  exit 1
fi

request GET /v1/users/me
expect_status 200 "读取当前用户"
expect_body "\"email\":\"$EMAIL\"" "当前用户邮箱"
expect_body '"id":"' "当前用户 ID"

request PATCH /v1/users/me --data '{"displayName":"smoke-name"}'
expect_status 200 "修改昵称"
expect_body '"displayName":"smoke-name"' "昵称已更新"

request GET /v1/users/me/devices
expect_status 200 "读取我的设备"
expect_body '"devices":' "设备列表字段"

if [ -n "$CLAIM_CODE" ]; then
  request DELETE "/v1/devices/$DEVICE_ID/binding"
  case "$STATUS" in
    204|403|404) pass "前置清理（$STATUS）" ;;
    *) fail "前置清理：意外状态 $STATUS（$BODY）" ;;
  esac

  request POST /v1/devices:bind \
    --data "{\"deviceId\":\"$DEVICE_ID\",\"claimCode\":\"$CLAIM_CODE\",\"label\":\"user-smoke\"}"
  expect_status 200 "绑定演示设备"
  expect_body '"bound":true' "绑定响应"

  request GET /v1/users/me/devices
  expect_status 200 "绑定后读取我的设备"
  expect_body "\"id\":\"$DEVICE_ID\"" "设备出现在我的设备"

  request DELETE "/v1/devices/$DEVICE_ID/binding"
  expect_status 204 "解绑演示设备"

  request GET "/v1/devices/$DEVICE_ID"
  expect_status 403 "解绑后车主不可见"
  expect_body '"forbidden"' "解绑后错误码"
fi

if [ "$failures" -ne 0 ]; then
  echo "== 失败 $failures 项 ==" >&2
  exit 1
fi
echo "== 全部通过 =="
