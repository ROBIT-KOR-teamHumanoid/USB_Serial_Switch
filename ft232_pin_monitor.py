"""FT232 button box wiring check: prints all four input pins live.

    python3 ft232_pin_monitor.py

ON  = pin pulled to GND (what the hotkey treats as "pressed")
off = pin released (idle)

Safe to run while ft232-hotkey service is running (read only, same open
settings). Ctrl+C to quit.
"""
import time

import serial

PORT = "/dev/FT232-HOTKEY"

# label on the button box -> pin (BTN2 has no wire; RI is tied to GND, not read)
PINS = (
    ("BTN1 DCD", lambda s: s.cd),
    ("BTN3 DSR", lambda s: s.dsr),
    ("BTN4 CTS", lambda s: s.cts),
)

ser = serial.Serial(PORT, 9600)

prev = None
try:
    while True:
        cur = tuple(read(ser) for _, read in PINS)
        if cur != prev:
            row = "   ".join(
                f"{name}: {'ON ' if on else 'off'}"
                for (name, _), on in zip(PINS, cur)
            )
            print(f"{time.strftime('%H:%M:%S')}   {row}", flush=True)
            prev = cur
        time.sleep(0.01)
except KeyboardInterrupt:
    pass
