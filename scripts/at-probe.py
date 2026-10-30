# AT probe for EC800M over UART, run inside MicroPython on the ESP32-S3.
#
# ASCII only on purpose: this file is shipped through the raw REPL, and
# non-ASCII bytes can get mangled by the serial link.
#
# Edit the pin numbers below to match your actual wiring.

import machine
import time

TX_PIN = 17
RX_PIN = 16
BAUD = 115200
CTRL_POWER_PIN = None   # set to e.g. 15 if PWRKEY is wired to a GPIO

u = machine.UART(1, baudrate=BAUD, tx=TX_PIN, rx=RX_PIN, timeout=300)


def drain(ms):
    time.sleep_ms(ms)
    data = u.read()
    return data if data else b''


def at(cmd, wait_ms=800):
    u.write((cmd + '\r\n').encode())
    return drain(wait_ms)


if CTRL_POWER_PIN is not None:
    # EC800M needs PWRKEY low for >1s to power on.
    p = machine.Pin(CTRL_POWER_PIN, machine.Pin.OUT)
    p.value(1)
    time.sleep(0.2)
    p.value(0)
    time.sleep(1.2)
    p.value(1)
    time.sleep(2.0)

print('=== UART echo test ===')
u.write((chr(13) + chr(10)).encode())
print('blank ->', drain(300))

print('=== AT commands ===')
for cmd in ('AT', 'ATE0', 'ATI', 'AT+CPIN?', 'AT+CSQ', 'AT+CREG?', 'AT+CGREG?'):
    print(cmd, '->', at(cmd))

print('=== GNSS ===')
print('AT+QGPS=1 ->', at('AT+QGPS=1', 1500))
print('AT+QGPSLOC? ->', at('AT+QGPSLOC?', 2000))
print('done')
