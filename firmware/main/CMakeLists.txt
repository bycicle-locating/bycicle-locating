idf_component_register(
    SRCS
        "main.c"
        "app_types.c"
        "proto/proto_encode.c"
        "track/ringbuf.c"
        "track/uploader.c"
        "modem/modem_at.c"
        "modem/modem_mqtt.c"
        "modem/modem_gnss.c"
        "ble/ble_status.c"
        "power/power_mgr.c"
    INCLUDE_DIRS
        "."
        "proto"
        "track"
        "modem"
        "ble"
        "power"
    REQUIRES
        nvs_flash
        esp_timer
        driver
        esp_netif
)

# M1 实现 BLE GATT 时追加：
#     REQUIRES bt
# 并确保 sdkconfig.defaults 中启用 CONFIG_BT_ENABLED / CONFIG_BT_NIMBLE_ENABLED。
