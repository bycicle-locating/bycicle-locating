#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

/*
 * 用 EC800M 内置 MQTT 栈收发消息。
 *
 * 为什么不用 ESP-IDF 自带的 esp-mqtt：ESP32 侧要自己跑 TCP + TLS，还要承担
 * 断线重连与证书管理；而模组已经做好了这套，并且省一层电量开销。
 *
 * 建立连接的指令序列（Quectel AT 手册，MQTT 章节）：
 *   AT+QMTCFG="version",0,4          → MQTT 3.1.1
 *   AT+QMTCFG="ssl",0,1,<ctx>        → 仅在 TLS 时
 *   AT+QMTOPEN=0,"<host>",8883       → 等 +QMTOPEN: 0,0
 *   AT+QMTCONN=0,"<clientId>","<user>","<pass>"  → 等 +QMTCONN: 0,0,0
 *
 * 发布：
 *   AT+QMTPUBEX=0,<msgId>,1,0,"<topic>",<len>
 *   等 '>' 后发送载荷（裸字节，末尾跟 Ctrl-Z 或按手册以长度为准），
 *   再等 OK 与 +QMTPUB: 0,<msgId>,0
 *
 * 订阅（下行指令）：
 *   AT+QMTSUB=0,<msgId>,"v1/device/<id>/cmd",1
 *   URC：+QMTRECV: 0,<msgId>,"<topic>",<len>
 */

typedef struct {
    const char *broker_host;   /* 只写主机名，协议与端口分开配置可避免拼串出错 */
    uint16_t    broker_port;   /* 生产 8883 */
    const char *client_id;     /* 通常等于 deviceId */
    const char *username;      /* deviceId */
    const char *password;      /* NVS 中的 deviceSecret */
    bool        use_tls;
} bkl_mqtt_config_t;

esp_err_t bkl_mqtt_connect(const bkl_mqtt_config_t *cfg);
esp_err_t bkl_mqtt_disconnect_graceful(void);
esp_err_t bkl_mqtt_publish(const char *topic, const char *payload, size_t len,
                           uint8_t qos, bool retain);
esp_err_t bkl_mqtt_subscribe_cmd(const char *device_id);
bool      bkl_mqtt_connected(void);
