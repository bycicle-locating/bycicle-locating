#!/usr/bin/env bash
# Postgres 全链路：postgres → migrate → backend(JWT) → nginx → 用户 API。
# 本地/CI 验证用；CI 里作为非必需 job 运行，避免数据库镜像与网络让流水线变脆。
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backend_dir=$(dirname "$script_dir")
cd "$backend_dir"

command -v docker >/dev/null || { echo "需要 docker" >&2; exit 1; }
docker compose version >/dev/null || { echo "需要 docker compose v2" >&2; exit 1; }
command -v openssl >/dev/null || { echo "需要 openssl" >&2; exit 1; }
command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }

new_claim() {
  local claim=""
  while [ "${#claim}" -lt 16 ]; do
    claim=$(openssl rand -base64 32 | LC_ALL=C tr -dc 'A-Z2-7')
  done
  printf '%s' "${claim:0:16}"
}

port=${BKL_E2E_PG_PORT:-18081}
project="bkl-e2e-pg-$$"
claim=$(new_claim)
pepper=$(openssl rand -base64 32)
pgpass=$(openssl rand -hex 24)
jwt_secret=$(openssl rand -hex 32)

export COMPOSE_PROJECT_NAME=$project
export BKL_HTTP_PORT=$port
export CLAIM_PEPPER=$pepper
export POSTGRES_PASSWORD=$pgpass
export DATABASE_URL="postgres://bkl:$pgpass@postgres:5432/bike_locating?sslmode=disable"
export JWT_SECRET=$jwt_secret
export JWT_TTL=1h
export DEV_USER_ID=
export DEV_SEED_CLAIM=$claim
export APP_ENV=dev
export BKL_IMAGE_TAG=users-e2e-pg
export GOPROXY=${GOPROXY:-https://proxy.golang.org,direct}

cleanup() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    docker compose --profile deps logs --no-color --tail=80 >&2 || true
  fi
  docker compose --profile deps down -v --remove-orphans >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

case "$port" in
  ''|*[!0-9]*) echo "BKL_E2E_PG_PORT 必须是数字：$port" >&2; exit 1 ;;
esac

echo "== 启动 Postgres 栈：project=$project port=$port =="
# backend 的 depends_on 会先跑完 migrate；这里顺带验证该顺序。
docker compose --profile deps up -d --build --wait --wait-timeout 240 backend nginx

for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$port/healthz"; then
    break
  fi
  sleep 1
done
if ! curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$port/healthz"; then
  echo "FAIL 后端未就绪" >&2
  exit 1
fi

BASE_URL="http://127.0.0.1:$port" \
DEVICE_ID=BKL-2026-000001 \
CLAIM_CODE="$claim" \
  bash "$script_dir/user-smoke.sh"

echo "== Postgres 全链路测试通过 =="
