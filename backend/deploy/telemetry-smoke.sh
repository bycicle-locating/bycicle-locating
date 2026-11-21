#!/usr/bin/env bash
# 只读检查健康状态与遥测路由的匿名鉴权。
set -euo pipefail

base_url=${BASE_URL:-http://127.0.0.1:32525}
base_url=${base_url%/}
device_path=/v1/devices/BKL-2026-000000

check_response() {
  local path=$1 expected_status=$2 expected_body=$3 response status body
  if ! response=$(curl -q -sS --max-time 10 --proto '=http,https' \
      -w '\n%{http_code}' --url "$base_url$path"); then
    printf 'FAIL %s 请求失败\n' "$path" >&2
    return 1
  fi
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  if [[ $status != "$expected_status" || ! $body =~ $expected_body ]]; then
    printf 'FAIL %s 期望 HTTP %s 及应用 JSON，实际 HTTP %s\n' \
      "$path" "$expected_status" "$status" >&2
    return 1
  fi
  printf 'PASS %s HTTP %s\n' "$path" "$status"
}

result=0
check_response /healthz 200 '"status"[[:space:]]*:[[:space:]]*"ok"' || result=1
for resource in location track; do
  check_response "$device_path/$resource" 401 '"error"[[:space:]]*:[[:space:]]*"unauthenticated"' || result=1
done
exit "$result"
