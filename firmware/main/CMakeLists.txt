idf_component_register(
    SRCS
        "main.c"
        "app_types.c"
        "proto/proto_encode.c"
        "track/ringbuf.c"
        "track/uploader.c"
        "audio/tone_gen.c"
        "audio/audio_out.c"
        "modem/modem_at.c"
        "modem/modem_mqtt.c"
        "modem/modem_gnss.c"
        "ble/ble_status.c"
        "nfc/st25dv.c"
        "power/power_mgr.c"
    INCLUDE_DIRS
        "."
        "proto"
        "track"
        "audio"
        "modem"
        "ble"
        "nfc"
        "power"
    REQUIRES
        nvs_flash
        esp_timer
        driver
        esp_netif
)

# driver 组件在 IDF 5.0/5.1 里包含 i2s_std，5.2+ 由 esp_driver_i2s 提供但 driver 仍做兼容转发，
# 所以这里不额外列 esp_driver_i2s，避免在 5.1 上找不到组件。

# M1 实现 BLE GATT 时追加：
#     REQUIRES bt
# 并确保 sdkconfig.defaults 中启用 CONFIG_BT_ENABLED / CONFIG_BT_NIMBLE_ENABLED。
