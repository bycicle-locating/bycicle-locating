# Network / data-path probe for EC800M over UART, run inside MicroPython.
#
# Verifies the prerequisites for MQTT: PDP context activation and DNS.
# ASCII only (shipped through the raw REPL).
#
# PIN must match the wiring; verified 2026-10-30 as TX=17, RX=16.

import machine
import time

TX_PIN = 17
RX_PIN = 16
BAUD = 115200

u = machine.UART(1, baudrate=BAUD, tx=TX_PIN, rx=RX_PIN, timeout=500)


def at(cmd, wait_ms=1000):
    u.write((cmd + '\r\n').encode())
    time.sleep_ms(wait_ms)
    data = u.read()
    return data if data else b''


print('=== APN / network info ===')
for cmd in ('AT+CGDCONT?', 'AT+QNWINFO', 'AT+CGATT?', 'AT+CPSMS?'):
    print(cmd, '->', at(cmd))

print('=== PDP context ===')
# 561 = context already activated, which is also fine.
print('AT+QIACT=1 ->', at('AT+QIACT=1', 5000))
print('AT+QIACT? ->', at('AT+QIACT?', 2000))

print('=== DNS ===')
print('AT+QIDNSGIP ->', at('AT+QIDNSGIP=1,"www.baidu.com"', 5000))

print('done')
