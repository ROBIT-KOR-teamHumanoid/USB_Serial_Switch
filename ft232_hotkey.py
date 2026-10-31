import os
import serial
import time
import subprocess

PORT = "/dev/FT232-HOTKEY"
MANAGER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "robot_manager.sh"
)

HOLD_TIME = 3.0

# button number = label on the button box
# (RI is tied to GND on the board, so BTN2 has no input pin)
BUTTONS = (1, 3, 4)

pressed_time = {btn: None for btn in BUTTONS}

triggered = {btn: False for btn in BUTTONS}

# a button only counts after it has been seen released once,
# so a stuck / held button never fires on service start
armed = {btn: False for btn in BUTTONS}


def run_manager(command):
    print(f"\n>>> robot_manager.sh {command}")

    subprocess.Popen([
        MANAGER,
        command
    ])


def all_start():
    run_manager("start")


def toggle_play():
    run_manager("toggle-play")


def stop_all():
    run_manager("stop-all")


actions = {
    1: all_start,
    3: toggle_play,
    4: stop_all,
}


ser = serial.Serial(PORT, 9600)

print()
print("======================================")
print(" ROBIT FT232 EXTERNAL CONTROL")
print("======================================")
print("BTN1 : ALL START       [3 sec]")
print("BTN2 : UNUSED")
print("BTN3 : PLAY <-> INIT   [3 sec]")
print("BTN4 : ALL STOP        [3 sec]")
print("======================================")
print()


def read_states():
    # button number -> FT232 pin
    return {
        1: ser.cd,   # DCD
        3: ser.dsr,  # DSR
        4: ser.cts,  # CTS
    }


held_at_start = [btn for btn, pressed in read_states().items() if pressed]

for btn in held_at_start:
    print(f"BTN{btn} held at start -> ignored until released")


while True:

    states = read_states()

    now = time.monotonic()

    for btn, pressed in states.items():

        if not armed[btn]:

            if not pressed:
                armed[btn] = True

                if btn in held_at_start:
                    print(f"BTN{btn} released -> active")

            continue

        if pressed:

            if pressed_time[btn] is None:
                pressed_time[btn] = now
                triggered[btn] = False

                print(f"BTN{btn} pressed")

            elif not triggered[btn]:

                elapsed = now - pressed_time[btn]

                if elapsed >= HOLD_TIME:
                    triggered[btn] = True

                    print(
                        f"BTN{btn} TRIGGERED "
                        f"({HOLD_TIME:.1f} sec)"
                    )

                    actions[btn]()

        else:

            if pressed_time[btn] is not None:
                print(f"BTN{btn} released")

            pressed_time[btn] = None
            triggered[btn] = False

    time.sleep(0.02)
