#!/usr/bin/env bash
# 从零拉起一份隔离的 compose 栈（nginx + backend），跑完冒烟后销毁。
#
# 与服务器上的部署实例互不影响：使用独立的 compose project 与宿主机端口。
# 用法：
#   ./deploy/e2e.sh                 # 默认端口 18080
#   BKL_E2E_PORT=18081 ./deploy/e2e.sh
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backend_dir=$(dirname "$script_dir")
cd "$backend_dir"

command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }
docker compose version >/dev/null || { echo "需要 docker compose v2" >&2; exit 1; }
command -v openssl >/dev/null || { echo "需要 openssl" >&2; exit 1; }

new_claim() {
  local claim=""
  while [ "${#claim}" -lt 16 ]; do
    claim=$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Z2-7')
  done
  printf '%s' "${claim:0:16}"
}

port=${BKL_E2E_PORT:-18080}
# 强制唯一 project：避免外部 COMPOSE_PROJECT_NAME 指向生产，cleanup 的 down -v 误删生产卷。
project="bkl-e2e-$$"
claim=$(new_claim)
pepper=$(openssl rand -base64 32)
postgres_password=$(openssl rand -base64 24)
jwt_secret=$(openssl rand -hex 32)
dev_user=11111111-1111-1111-1111-111111111111
device=BKL-2026-000001

export COMPOSE_PROJECT_NAME=$project
export BKL_HTTP_PORT=$port
export CLAIM_PEPPER=$pepper
export POSTGRES_PASSWORD=$postgres_password
# 显式空：不让调用者环境的 DATABASE_URL 把 e2e 连到外部数据库。
export DATABASE_URL=
export JWT_SECRET=$jwt_secret
# 故意留空：验证无身份请求会得到 401，而不是回退到固定用户。
export DEV_USER_ID=
export DEV_SEED_CLAIM=$claim
export APP_ENV=dev
# 与部署镜像分开，避免 e2e 重建把部署实例正在使用的 tag 挪走。
export BKL_IMAGE_TAG=e2e

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    docker compose logs --no-color --tail=50 >&2 || true
  fi
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

case "$port" in
  ''|*[!0-9]*) echo "BKL_E2E_PORT 必须是数字：$port" >&2; exit 1 ;;
esac

echo "== 启动隔离栈：project=$project port=$port =="
docker compose up -d --build --wait --wait-timeout 120

backend_id=$(docker compose ps -q backend)
backend_bindings=$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$backend_id")
case "$backend_bindings" in
  '{}'|'null') : ;;
  *)
    echo "FAIL backend 不应发布宿主机端口（只允许 nginx 对外）：$backend_bindings" >&2
    exit 1
    ;;
esac
echo "  ok   backend 未发布宿主机端口"

nginx_id=$(docker compose ps -q nginx)
published=$(docker inspect -f '{{with (index .HostConfig.PortBindings "8080/tcp")}}{{(index . 0).HostPort}}{{end}}' "$nginx_id")
if [ "$published" != "$port" ]; then
  echo "FAIL nginx 未按预期发布到宿主机 $port（实际：${published:-无}）" >&2
  exit 1
fi
echo "  ok   nginx 发布到宿主机 $port"

BASE_URL="http://127.0.0.1:$port" \
CLAIM_CODE="$claim" \
DEV_USER_ID="$dev_user" \
DEVICE_ID="$device" \
EXPECT_UNAUTHENTICATED=1 \
  "$script_dir/smoke.sh"

echo "== 用户 API 冒烟 =="
BASE_URL="http://127.0.0.1:$port" \
CLAIM_CODE="$claim" \
DEVICE_ID="$device" \
CHECK_RATE_LIMIT=1 \
  bash "$script_dir/user-smoke.sh"

# 重建 backend 会分配新 IP；验证 nginx 的 resolver 配置能让链路自动恢复。
echo "== 重建 backend，验证 nginx 自动恢复 =="
docker compose up -d --force-recreate --no-deps backend >/dev/null
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/healthz"; then
    break
  fi
  sleep 1
done
if ! curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$port/healthz"; then
  echo "FAIL 重建 backend 后链路未恢复" >&2
  exit 1
fi
echo "  ok   重建后链路恢复"

echo "== 全链路测试通过 =="
