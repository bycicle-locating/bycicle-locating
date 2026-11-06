-- 初始 schema：用户、设备、绑定审计、轨迹、事件、在线状态。
-- PostGIS 暂不启用；坐标用 lat/lon double precision。
-- 本文件可重复执行（配合 psql -1），便于 deploy/migrate 重跑。

CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version    text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
    id            uuid PRIMARY KEY,
    email         citext NOT NULL UNIQUE,
    password_hash text NOT NULL,
    display_name  text,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS devices (
    id                         text PRIMARY KEY,
    model                      text NOT NULL,
    claim_code_hash            text,
    claim_code_prev_hash       text,
    claim_code_prev_expires_at timestamptz,
    device_secret_hash         text,
    claimed_by                 uuid REFERENCES users(id),
    claimed_at                 timestamptz,
    state                      text NOT NULL CHECK (state IN ('FACTORY', 'CLAIMABLE', 'CLAIMED')),
    fw_version                 text,
    last_seen_at               timestamptz,
    last_fix_at                timestamptz,
    label                      text,
    config                     jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS devices_claimed_by_idx
    ON devices (claimed_by) WHERE claimed_by IS NOT NULL;

CREATE TABLE IF NOT EXISTS device_bindings (
    id         bigserial PRIMARY KEY,
    device_id  text NOT NULL REFERENCES devices(id),
    user_id    uuid NOT NULL REFERENCES users(id),
    bound_at   timestamptz NOT NULL DEFAULT now(),
    unbound_at timestamptz,
    reason     text NOT NULL DEFAULT 'user_table'
);

CREATE UNIQUE INDEX IF NOT EXISTS device_bindings_open_idx
    ON device_bindings (device_id)
    WHERE unbound_at IS NULL;

-- 绑定/解绑的审计写入由触发器完成，避免应用层同一次绑定发两条 SQL。
CREATE OR REPLACE FUNCTION record_device_binding() RETURNS trigger AS $$
BEGIN
    IF OLD.claimed_by IS NULL AND NEW.claimed_by IS NOT NULL THEN
        INSERT INTO device_bindings (device_id, user_id, bound_at, reason)
        VALUES (NEW.id, NEW.claimed_by, now(), 'user_table');
    ELSIF OLD.claimed_by IS NOT NULL AND NEW.claimed_by IS NULL THEN
        UPDATE device_bindings SET unbound_at = now()
        WHERE device_id = NEW.id AND unbound_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS devices_binding_history ON devices;
CREATE TRIGGER devices_binding_history
    AFTER UPDATE OF claimed_by ON devices
    FOR EACH ROW EXECUTE FUNCTION record_device_binding();

CREATE TABLE IF NOT EXISTS telemetry_points (
    device_id   text NOT NULL,
    seq         bigint NOT NULL,
    ts          timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    lat         double precision,
    lon         double precision,
    speed_mps   real,
    course_deg  real,
    alt_m       real,
    hdop        real,
    fix         smallint NOT NULL DEFAULT 0,
    quality     smallint NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, seq)
);

CREATE INDEX IF NOT EXISTS telemetry_points_device_ts_idx
    ON telemetry_points (device_id, ts DESC);

CREATE TABLE IF NOT EXISTS events (
    id          bigserial PRIMARY KEY,
    device_id   text NOT NULL,
    seq         bigint NOT NULL,
    ts          timestamptz NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    type        text NOT NULL,
    level       text NOT NULL,
    lat         double precision,
    lon         double precision,
    data        jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS events_device_ts_idx ON events (device_id, ts DESC);
CREATE INDEX IF NOT EXISTS events_type_ts_idx ON events (type, ts DESC);
-- 事件与轨迹点走同一条 QoS/重传链路，按 (device_id, seq) 去重。
CREATE UNIQUE INDEX IF NOT EXISTS events_device_seq_idx ON events (device_id, seq);

CREATE TABLE IF NOT EXISTS device_status (
    device_id  text PRIMARY KEY,
    online     boolean NOT NULL,
    firmware   text,
    battery_mv integer,
    at         timestamptz NOT NULL
);

INSERT INTO schema_migrations (version) VALUES ('0001_init.sql')
    ON CONFLICT (version) DO NOTHING;
