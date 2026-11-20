#!/usr/bin/env bash
# 使用独立 Compose 工程验证登记、MQTT 入库和车主轨迹查询。
set -euo pipefail

cd "$(dirname -- "$0")/.."
test_dir=$(mktemp -d)
mkdir "$test_dir/broker" "$test_dir/ca"
project="bkl-e2e-mqtt-$$"
wrong_ca_container="$project-wrong-ca"

export BKL_MQTT_TEST_DIR=$test_dir
if command -v cygpath >/dev/null; then
  export BKL_MQTT_TEST_DIR=$(cygpath -am "$test_dir")
  export MSYS_NO_PATHCONV=1
fi
export BKL_MQTT_TEST_USER="$(id -u):$(id -g)"
export APP_ENV=prod
export BKL_IMAGE_TAG=$project
export CLAIM_PEPPER=$(openssl rand -hex 16)
export DEV_SEED_CLAIM=
export POSTGRES_PASSWORD=$(openssl rand -hex 24)
export DATABASE_URL="postgres://bkl:$POSTGRES_PASSWORD@postgres:5432/bike_locating?sslmode=disable"
export JWT_SECRET=$(openssl rand -hex 32)
export MQTT_URL=mqtts://broker-tls:8883
export MQTT_USER=backend
export MQTT_PASSWORD=$(openssl rand -hex 24)
export MQTT_CLIENT_ID=bkl-e2e-mqtt
export MQTT_CA_DIR="$BKL_MQTT_TEST_DIR/ca"
export MQTT_CA_FILE=/run/bkl/mqtt/mqtt-ca.crt
device=BKL-2026-000001
device_pass=$(openssl rand -hex 24)

compose() {
  docker compose --env-file "$BKL_MQTT_TEST_DIR/test.env" -p "$project" \
    -f docker-compose.yml -f "$BKL_MQTT_TEST_DIR/compose.yml" --profile deps "$@"
}

cleanup() {
  local status=$?
  if [ -f "$test_dir/compose.yml" ]; then
    if [ "$status" -ne 0 ]; then
      compose logs --no-color --tail=35 backend broker-tls postgres >&2 || true
    fi
    docker rm -f "$wrong_ca_container" >/dev/null 2>&1 || true
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f -- "$test_dir"/{compose.yml,test.env,server.csr,server.ext,ca.key,ca.srl} \
    "$test_dir"/broker/{mosquitto.conf,acl,passwd,server.key,server.crt} \
    "$test_dir"/ca/{mqtt-ca.crt,wrong-ca.crt}
  rmdir -- "$test_dir/broker" "$test_dir/ca" "$test_dir" || true
  exit "$status"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -subj '/CN=BKL MQTT Test CA' -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$BKL_MQTT_TEST_DIR/ca.key" -out "$BKL_MQTT_TEST_DIR/ca/mqtt-ca.crt"
openssl req -newkey rsa:2048 -nodes -subj /CN=broker-tls \
  -keyout "$BKL_MQTT_TEST_DIR/broker/server.key" -out "$BKL_MQTT_TEST_DIR/server.csr"
cat >"$test_dir/server.ext" <<'EOF'
subjectAltName=DNS:broker-tls
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
openssl x509 -req -in "$BKL_MQTT_TEST_DIR/server.csr" -CA "$BKL_MQTT_TEST_DIR/ca/mqtt-ca.crt" \
  -CAkey "$BKL_MQTT_TEST_DIR/ca.key" \
  -CAserial "$BKL_MQTT_TEST_DIR/ca.srl" -CAcreateserial -days 2 -sha256 -extfile "$BKL_MQTT_TEST_DIR/server.ext" \
  -out "$BKL_MQTT_TEST_DIR/broker/server.crt"
chmod a+r "$test_dir/ca/mqtt-ca.crt"
cp deploy/certs/mqtt-ca.crt "$test_dir/ca/wrong-ca.crt"

for identity in "$MQTT_USER" "$device"; do
  if [ "$identity" = "$MQTT_USER" ]; then
    password=$MQTT_PASSWORD
    create_file=(-c)
  else
    password=$device_pass
    create_file=()
  fi
  docker run --rm --user "$BKL_MQTT_TEST_USER" \
    --mount "type=bind,source=$BKL_MQTT_TEST_DIR/broker,target=/test" \
    --entrypoint mosquitto_passwd eclipse-mosquitto:2 \
    -b "${create_file[@]}" /test/passwd "$identity" "$password"
done

cat >"$test_dir/broker/mosquitto.conf" <<'EOF'
listener 8883
allow_anonymous false
password_file /test/passwd
acl_file /test/acl
cafile /ca/mqtt-ca.crt
certfile /test/server.crt
keyfile /test/server.key
tls_version tlsv1.2
message_size_limit 4096
EOF
cat >"$test_dir/broker/acl" <<EOF
user $device
topic write v1/device/$device/telemetry
topic write v1/device/$device/event
user $MQTT_USER
topic read v1/device/+/telemetry
topic read v1/device/+/event
topic read v1/device/+/status
topic read v1/device/+/cmd/ack
EOF
: >"$test_dir/test.env"
cat >"$test_dir/compose.yml" <<'EOF'
services:
  backend:
    restart: "no"
    ports:
      - "127.0.0.1::8080"
  postgres:
    ports: !reset []
  broker-tls:
    image: eclipse-mosquitto:2
    user: "${BKL_MQTT_TEST_USER}"
    entrypoint: ["mosquitto", "-c", "/test/mosquitto.conf"]
    volumes:
      - "${BKL_MQTT_TEST_DIR}/broker:/test:ro"
      - "${MQTT_CA_DIR}:/ca:ro"
    networks: [data]
EOF

wait_until() {
  local name=$1
  shift
  for ((attempt = 0; attempt < 25; attempt++)); do
    if "$@"; then return 0; fi
    sleep 1
  done
  printf 'FAIL %s\n' "$name" >&2
  return 1
}

broker_ready() {
  compose exec -T broker-tls mosquitto_sub -h broker-tls -p 8883 --cafile /ca/mqtt-ca.crt \
    -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t 'v1/device/+/telemetry' -q 1 -E -W 2 >/dev/null 2>&1
}

compose up -d broker-tls
wait_until "TLS Broker 未就绪" broker_ready
compose up -d --build --wait --wait-timeout 240 backend
api="http://$(compose port backend 8080 | tr -d '\r')"

register_device() {
  compose run --rm --no-deps -T --entrypoint /usr/local/bin/bkl-device-admin \
    backend -id "$device" -model BKL1
}
registration=$(register_device)
if [[ ! $registration =~ ^deviceId=$device[[:space:]]claimCode=([A-Z2-7]{16})$ ]]; then
  printf '%s\n' 'FAIL 登记应返回 16 位 Base32 声明码' >&2
  exit 1
fi
claim=${BASH_REMATCH[1]}
if duplicate=$(register_device 2>/dev/null) || [ -n "$duplicate" ]; then
  printf '%s\n' 'FAIL 重复登记应失败且不输出声明码' >&2
  exit 1
fi

register_user() {
  curl -fsS -H 'Content-Type: application/json' \
    --data "{\"email\":\"$1@example.com\",\"password\":\"$(openssl rand -hex 16)\"}" \
    "$api/v1/auth/register" | sed -nE 's/.*"token":"([^"]+)".*/\1/p'
}
bind_device() {
  curl -fsS -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    --data "{\"deviceId\":\"$device\",\"claimCode\":\"$claim\"}" "$api/v1/devices:bind" >/dev/null
}
owner_token=$(register_user "$project-owner")
other_token=$(register_user "$project-other")
if [ -z "$owner_token" ] || [ -z "$other_token" ]; then
  printf '%s\n' 'FAIL 注册响应缺少 JWT' >&2
  exit 1
fi

telemetry_topic="v1/device/$device/telemetry"
point_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
publish() {
  local seq=$1 topic=$2 id=$3 payload
  printf -v payload '{"v":1,"id":"%s","seq":%d,"ts":"%s","type":"telemetry","fw":"0.1.0","points":[{"seq":%d,"t":"%s","lat":31.23,"lon":121.47,"spd":2.5,"crs":0,"fix":3}]}' \
    "$id" "$seq" "$point_time" "$seq" "$point_time"
  compose exec -T broker-tls mosquitto_pub -h broker-tls -p 8883 --cafile /ca/mqtt-ca.crt \
    -u "$device" -P "$device_pass" -q 1 -t "$topic" -m "$payload"
}

has_sequences() {
  local rows
  rows=$(compose exec -T postgres psql -X -Aqt -v ON_ERROR_STOP=1 -U bkl -d bike_locating \
    -c "SELECT string_agg(seq::text, ',' ORDER BY seq) FROM telemetry_points WHERE device_id = 'BKL-2026-000001'") || return 1
  [ "$rows" = "$1" ]
}

publish 40 "$telemetry_topic" "$device"
wait_until "绑定前上报应已入库" has_sequences 40
bind_device "$owner_token"
sleep 1
point_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

publish 41 "$telemetry_topic" "$device"
publish 41 "$telemetry_topic" "$device"
publish 42 "v1/device/$device/event" "$device"
publish 43 "$telemetry_topic" BKL-2026-000099
publish 44 "$telemetry_topic" "$device"
wait_until "有效点入库、重传去重或无效报文隔离失败" has_sequences 40,41,44

retry_seen() {
  compose logs --no-color backend 2>&1 | grep -F 'MQTT 报文处理失败，稍后重试' >/dev/null
}
compose stop postgres
publish 45 "$telemetry_topic" "$device"
wait_until "数据库中断时应保留未确认的报文" retry_seen
compose stop backend
compose up -d --wait backend
api="http://$(compose port backend 8080 | tr -d '\r')"
wait_until "复用 MQTT 会话后应收到未确认报文" has_sequences 40,41,44,45

connection_count() {
  compose logs --no-color backend 2>&1 | awk '/MQTT 已连接并订阅/ { count++ } END { print count+0 }'
}
subscribed_again() {
  [ "$(connection_count)" -gt "$1" ]
}
previous_connections=$(connection_count)
compose restart broker-tls
wait_until "Broker 重启后应自动重订阅" subscribed_again "$previous_connections"
publish 46 "$telemetry_topic" "$device"
wait_until "Broker 重启后应继续入库" has_sequences 40,41,44,45,46

compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U bkl -d bike_locating \
  -c 'ALTER TABLE telemetry_points ADD CONSTRAINT e2e_block_seq_47 CHECK (seq <> 47)' >/dev/null
publish 47 "$telemetry_topic" "$device"
publish 48 "$telemetry_topic" "$device"
wait_until "永久数据错误应丢弃并继续处理后续报文" has_sequences 40,41,44,45,46,48

device_api="$api/v1/devices/$device"
read_sequences() {
  curl -fsS -H "Authorization: Bearer $1" "$device_api/$2" |
    grep -oE '"seq":[0-9]+' | cut -d: -f2 | paste -sd, -
}
http_status() {
  local status
  status=$(curl -sS -w '\n%{http_code}\n' -H "Authorization: Bearer $1" "$device_api/$2" | tail -n 1) || return 1
  printf '%s\n' "$status"
}
if [ "$(read_sequences "$owner_token" location)" != 48 ] ||
    [ "$(read_sequences "$owner_token" track)" != 41,44,45,46,48 ] ||
    [ "$(read_sequences "$owner_token" 'track?limit=2')" != 46,48 ] ||
    [ "$(http_status "$other_token" track)" != 403 ]; then
  printf '%s\n' 'FAIL 车主最新位置、轨迹范围、限量或鉴权不符' >&2
  exit 1
fi

previous_point_time=$point_time
point_time=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
publish 49 "$telemetry_topic" "$device"
wait_until "设备时间超前的旧接收点应已入库" has_sequences 40,41,44,45,46,48,49
curl -fsS -X DELETE -H "Authorization: Bearer $owner_token" "$device_api/binding" >/dev/null
bind_device "$other_token"
point_time=$previous_point_time
publish 50 "$telemetry_topic" "$device"
wait_until "换绑后收到的旧采样点应已入库" has_sequences 40,41,44,45,46,48,49,50
if [ "$(http_status "$owner_token" location)" != 403 ] ||
    [ "$(http_status "$other_token" location)" != 404 ] ||
    [ "$(curl -fsS -H "Authorization: Bearer $other_token" "$device_api/track")" != '{"points":[]}' ]; then
  printf '%s\n' 'FAIL 换绑后泄露了旧轨迹或权限状态不符' >&2
  exit 1
fi
sleep 1
point_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
publish 51 "$telemetry_topic" "$device"
wait_until "新绑定的正常遥测应已入库" has_sequences 40,41,44,45,46,48,49,50,51
if [ "$(read_sequences "$other_token" location)" != 51 ] ||
    [ "$(read_sequences "$other_token" track)" != 51 ]; then
  printf '%s\n' 'FAIL 新车主应只看到本次绑定的正常点' >&2
  exit 1
fi

wrong_ca_exited() {
  [ "$(docker inspect --format '{{.State.Status}}' "$wrong_ca_container")" = exited ]
}
compose run --detach --no-deps --name "$wrong_ca_container" -e MQTT_CLIENT_ID=bkl-e2e-wrong-ca \
  -e MQTT_CA_FILE=/run/bkl/mqtt/wrong-ca.crt backend >/dev/null
wait_until "错误 CA 应使后端启动失败" wrong_ca_exited
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$wrong_ca_container")
rejected=$(docker logs "$wrong_ca_container" 2>&1)
if [ "$exit_code" -eq 0 ] || ! grep -F 'x509: certificate signed by unknown authority' <<< "$rejected" >/dev/null; then
  printf '%s\n' "$rejected" >&2
  printf '%s\n' 'FAIL 连接应因 CA 校验而失败' >&2
  exit 1
fi
printf '%s\n' 'PASS 设备登记、MQTT TLS 入库与恢复、车主轨迹查询和换绑数据隔离'
