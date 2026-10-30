# Board identity probe for bring-up, run inside MicroPython on the ESP32.
#
# Prints what the firmware/docs need to know: chip target, flash size, MAC,
# clock, free RAM. ASCII only (shipped through the raw REPL).

import esp
import gc
import machine
import sys

print('platform:', sys.platform)
print('mpy_version:', sys.implementation.version)

try:
    print('flash_size_bytes:', esp.flash_size())
except Exception as exc:  # noqa: BLE001
    print('flash_size_bytes: ERR', exc)

try:
    print('unique_id:', machine.unique_id().hex())
except Exception as exc:  # noqa: BLE001
    print('unique_id: ERR', exc)

try:
    print('cpu_freq_hz:', machine.freq())
except Exception as exc:  # noqa: BLE001
    print('cpu_freq_hz: ERR', exc)

try:
    print('mem_free_bytes:', gc.mem_free())
except Exception as exc:  # noqa: BLE001
    print('mem_free_bytes: ERR', exc)

try:
    import esp32
    print('mcu_temp_c:', esp32.mcu_temperature())
except Exception as exc:  # noqa: BLE001
    print('mcu_temp_c: n/a', exc)

print('done')
