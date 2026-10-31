#!/usr/bin/env bash

# colcon_ws/scripts/robot_manager.sh -> colcon_ws
WORKSPACE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
RUN_DIR="/tmp/robit_robot_manager"
LOG_DIR="$WORKSPACE/scripts/robot_logs"

# error lines in red (journalctl / terminal show the color, pipes strip it)
err()
{
    printf '\033[31m%s\033[0m\n' "$*"
}

# turn log lines into "        <message>" in red, dropping the node's own color codes
err_lines()
{
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^.*\]: /        /' | cut -c1-100 | \
        while IFS= read -r line; do err "$line"; done
}

# hotkey service does not read ~/.bashrc, so match its ROS settings here:
# - same RMW as the vision launches (rmw_cyclonedds_cpp)
# - same domain as the terminals (~/.bashrc ROS_DOMAIN_ID), else nodes are invisible
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=201

if [ ! -f "$WORKSPACE/install/setup.bash" ]; then
    err "[ERROR] $WORKSPACE/install/setup.bash not found (colcon build first)"
    exit 1
fi

mkdir -p "$RUN_DIR"
mkdir -p "$LOG_DIR"

# one command at a time (hotkey presses queue up instead of overlapping)
if [ "${1:-}" != "status" ]; then
    exec 9>"$RUN_DIR/manager.lock"
    if ! flock -w 60 9; then
        err "[ERROR] another robot_manager.sh is still running"
        exit 1
    fi
fi

declare -A CMD
CMD[dhi]="ros2 launch dynamixel_hardware_interface dynamixel_hardware.launch.py"
CMD[gamecontroller]="ros2 launch gamecontroller gamecontroller.launch.py"
CMD[ik_walk]="ros2 run ik_walk ik_walk"
# mani_debug_mode: True - grab/shoot run through humanoid_manipulation (activate_cmd),
# not motion_operator motion numbers. Plain mode: irc_task_planner.launch.py
CMD[task_planner]="ros2 launch irc_task_planner mani_debug_task_planner.launch.py"
CMD[insta360]="ros2 launch insta360_link irc_insta360_vision.launch.py"
CMD[realsense]="ros2 launch realsense irc_vision.launch.py"
CMD[motion_operator]="ros2 launch motion_operator motion_operator.launch.py"
CMD[manipulation]="ros2 launch humanoid_manipulation manipulation.launch.py use_rviz:=false"

# no display (hotkey service): skip the vision imshow debug windows
# (they would only be drawn offscreen and waste CPU)
if [ -z "${DISPLAY:-}" ]; then
    CMD[realsense]+=" show_rate_hz:=0.0"
    CMD[insta360]+=" show_imshow:=false"
fi

declare -A MATCH
MATCH[dhi]="dynamixel_hardware.launch.py"
MATCH[gamecontroller]="gamecontroller.launch.py"
MATCH[ik_walk]="ik_walk ik_walk"
MATCH[task_planner]="task_planner.launch.py"  # matches both planner launches
MATCH[insta360]="irc_insta360_vision.launch.py"
MATCH[realsense]="irc_vision.launch.py"
MATCH[motion_operator]="motion_operator.launch.py"
MATCH[manipulation]="humanoid_manipulation manipulation.launch.py"

# start order (after dhi torque is on)
# insta360 last: nothing waits for it, task_planner re-sends /insta360_enable
# every second and treats missing /insta360 data as "not found"
SERVICES=(
    dhi
    ik_walk
    realsense
    manipulation
    gamecontroller
    motion_operator
    task_planner
    insta360
)

pid_file()
{
    echo "$RUN_DIR/$1.pid"
}

log_file()
{
    echo "$LOG_DIR/$1.log"
}

# minimum seconds between stopping a node and starting it again
# (RealSense dropped off USB when reopened ~10 s after closing)
declare -A RESTART_DELAY
RESTART_DELAY[realsense]=5

stopped_file()
{
    echo "$RUN_DIR/$1.stopped"
}

LOG_MAX_BYTES=$((10 * 1024 * 1024))

# keep one old log: <name>.log -> <name>.log.1 when over 10 MB
rotate_log()
{
    local logfile
    logfile="$(log_file "$1")"

    if [ "$(stat -c %s "$logfile" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$logfile" "$logfile.1"
        echo "[LOG  ] $1.log > 10MB -> $1.log.1"
    fi
}

is_running()
{
    local name="$1"
    local pidfile
    pidfile="$(pid_file "$name")"

    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile" 2>/dev/null)"

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi

        rm -f "$pidfile"
    fi

    if pgrep -f "${MATCH[$name]}" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

start_service()
{
    local name="$1"

    if is_running "$name"; then
        echo "[KEEP ] $name"
        return 0
    fi

    echo "[START] $name"

    local delay="${RESTART_DELAY[$name]:-0}"
    if [ "$delay" -gt 0 ] && [ -f "$(stopped_file "$name")" ]; then
        local wait_s
        wait_s=$(( $(cat "$(stopped_file "$name")") + delay - $(date +%s) ))
        if [ "$wait_s" -gt 0 ]; then
            echo "[WAIT ] $name stopped just now -> wait ${wait_s}s before restart"
            sleep "$wait_s"
        fi
    fi

    local pidfile
    local logfile

    rotate_log "$name"

    pidfile="$(pid_file "$name")"
    logfile="$(log_file "$name")"

    # errors/warnings only (scripts/log_filter.awk); ROBOT_FULL_LOG=1 keeps everything
    # mawk -W interactive: line by line; plain mawk holds lines until the
    # node exits, which made the dhi torque check time out
    local filter="mawk -W interactive -v fold=1 -f '$WORKSPACE/scripts/log_filter.awk'"
    if [ "$name" = "dhi" ]; then
        filter="mawk -W interactive -v fold=0 -f '$WORKSPACE/scripts/log_filter.awk'"
    fi
    if [ "${ROBOT_FULL_LOG:-0}" = "1" ]; then
        filter="cat"
    fi

    # the filter ignores SIGINT/SIGTERM so it outlives the node and
    # writes its last lines when the node's output closes
    setsid bash -c "
        cd '$WORKSPACE' || exit 1
        export PYTHONUNBUFFERED=1
        # no display (hotkey service) -> Qt apps (gamecontroller) run headless
        [ -n \"\$DISPLAY\" ] || export QT_QPA_PLATFORM=offscreen
        source /opt/ros/jazzy/setup.bash
        source install/setup.bash
        ${CMD[$name]} 2>&1 | (trap '' INT TERM; exec $filter)
    " >> "$logfile" 2>&1 9>&- &

    local pid=$!
    echo "$pid" > "$pidfile"

    sleep 0.5

    if kill -0 "$pid" 2>/dev/null; then
        echo "[ OK  ] $name  PID=$pid"
    else
        err "[FAIL ] $name"
        err "        LOG: $logfile"
        rm -f "$pidfile"
        return 1
    fi
}

stop_service()
{
    local name="$1"
    local pidfile

    pidfile="$(pid_file "$name")"

    if ! is_running "$name"; then
        echo "[OFF  ] $name"
        rm -f "$pidfile"
        return 0
    fi

    echo "[STOP ] $name"

    if [ -f "$pidfile" ]; then
        local pid
        pid="$(cat "$pidfile" 2>/dev/null)"

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill -SIGINT -- "-$pid" 2>/dev/null || \
                kill -SIGINT "$pid" 2>/dev/null

            for _ in {1..30}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done

            if kill -0 "$pid" 2>/dev/null; then
                echo "[WARN ] $name still running -> SIGTERM"
                kill -SIGTERM -- "-$pid" 2>/dev/null || \
                    kill -SIGTERM "$pid" 2>/dev/null

                for _ in {1..20}; do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 0.1
                done

                if kill -0 "$pid" 2>/dev/null; then
                    echo "[WARN ] $name still running -> SIGKILL"
                    kill -SIGKILL -- "-$pid" 2>/dev/null || \
                        kill -SIGKILL "$pid" 2>/dev/null
                fi
            fi
        fi

        rm -f "$pidfile"

    else
        echo "[INFO ] manually started process detected"
        pkill -SIGINT -f "${MATCH[$name]}" 2>/dev/null || true
        sleep 0.5
    fi

    date +%s > "$(stopped_file "$name")"
}

dhi_lifecycle_state()
{
    timeout 10 bash -c "
        source /opt/ros/jazzy/setup.bash
        source '$WORKSPACE/install/setup.bash'
        ros2 lifecycle get /dynamixel_hardware_interface
    " 2>/dev/null | awk '{print $1}'
}

# watch the dhi log written after <offset>:
# configure pings every motor (fails if motor power is off),
# activate turns torque on
wait_dhi_torque()
{
    local logfile="$1"
    local offset="$2"
    local new

    for _ in {1..200}; do
        new="$(tail -c +"$((offset + 1))" "$logfile" 2>/dev/null)"

        if grep -q "Dynamixel hardware interface activated" <<< "$new"; then
            return 0
        fi

        if grep -q -E "\[ERROR\].*Failed to" <<< "$new"; then
            grep -E "\[ERROR\].*Failed to" <<< "$new" | err_lines
            return 1
        fi

        if ! is_running dhi; then
            err "        dhi process exited"
            return 1
        fi

        sleep 0.1
    done

    err "        timeout (20 sec)"
    return 1
}

# dhi stays "active" even if motor power is cut after activation;
# it then logs "Failed to read ..." about once a second
dhi_motor_alive()
{
    local logfile
    local offset
    local new

    if [ ! -f "$(pid_file dhi)" ]; then
        err "        dhi was not started by robot_manager (no log to check)"
        return 2
    fi

    logfile="$(log_file dhi)"
    offset="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"

    sleep 2.5

    new="$(tail -c +"$((offset + 1))" "$logfile" 2>/dev/null)"

    if grep -q -E "\[ERROR\].*Failed to read" <<< "$new"; then
        grep -E "\[ERROR\].*Failed to read" <<< "$new" | tail -n 1 | err_lines
        return 1
    fi

    return 0
}

start_all()
{
    echo
    echo "=========================================="
    echo " ROBIT : ALL START"
    echo "=========================================="
    echo

    if is_running dhi; then
        local state
        state="$(dhi_lifecycle_state)"

        if [ "$state" = "active" ]; then
            echo "[CHECK] dhi active -> checking motor response (2.5 sec)"

            local alive=0
            dhi_motor_alive || alive=$?

            if [ "$alive" -eq 2 ]; then
                echo
                err "[ABORT] cannot verify motor power -> dhi kept as is"
                err "        stop all (BTN4) and press BTN1 again"
                return 1
            fi

            if [ "$alive" -ne 0 ]; then
                echo
                err "[ABORT] dhi active but motors not responding (power off?)"
                err "        other nodes not started"
                stop_service dhi
                return 1
            fi

            echo "[KEEP ] dhi  (active, motors responding)"
        else
            echo "[INFO ] dhi running but ${state:-unknown} -> restart"
            stop_service dhi
        fi
    fi

    if ! is_running dhi; then
        local logfile
        local offset

        # rotate before taking the offset, so the torque check reads the right file
        rotate_log dhi

        logfile="$(log_file dhi)"
        offset="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"

        if ! start_service dhi || \
            ! wait_dhi_torque "$logfile" "$offset"; then
            echo
            err "[ABORT] motor power off or torque enable failed"
            err "        other nodes not started"
            stop_service dhi
            return 1
        fi

        echo "[TORQ ] dhi torque on"
    fi

    # EBIMU temporarily disabled

    local name
    for name in "${SERVICES[@]:1}"; do
        start_service "$name"
    done

    echo
    echo "=========================================="
    echo " ALL START CHECK COMPLETE"
    echo "=========================================="
}

stop_except_dhi()
{
    echo
    echo "=========================================="
    echo " ROBIT : STOP EXCEPT DHI"
    echo "=========================================="
    echo

    # same order as start, dhi (first) kept
    local name
    for name in "${SERVICES[@]:1}"; do
        stop_service "$name"
    done

    echo
    echo "[KEEP ] dhi"
    echo
    echo "=========================================="
    echo " ONLY DHI REMAINS"
    echo "=========================================="
}

stop_all()
{
    echo
    echo "=========================================="
    echo " ROBIT : STOP ALL"
    echo "=========================================="
    echo

    # same order as start
    local name
    for name in "${SERVICES[@]}"; do
        stop_service "$name"
    done

    echo
    echo "=========================================="
    echo " ALL STOPPED"
    echo "=========================================="
}

toggle_dhi()
{
    echo
    echo "=========================================="
    echo " ROBIT : DHI TOGGLE"
    echo "=========================================="

    if is_running dhi; then
        echo "DHI : ON -> OFF"
        stop_service dhi
    else
        echo "DHI : OFF -> ON"
        start_service dhi
    fi
}

toggle_play()
{
    echo
    echo "=========================================="
    echo " ROBIT : GAME STATE TOGGLE"
    echo "=========================================="

    if ! is_running gamecontroller; then
        err "[FAIL ] gamecontroller not running"
        return 1
    fi

    local result
    result="$(timeout 10 bash -c "
        source /opt/ros/jazzy/setup.bash
        source '$WORKSPACE/install/setup.bash'
        ros2 service call /gamecontroller/toggle_playing std_srvs/srv/Trigger
    " 2>&1 | grep -o "success=.*")"

    case "$result" in
        success=True*)
            echo "[ OK  ] state -> $(sed "s/.*message='\(.*\)'.*/\1/" <<< "$result")"
            ;;
        success=False*)
            err "[FAIL ] $(sed "s/.*message='\(.*\)'.*/\1/" <<< "$result")"
            return 1
            ;;
        *)
            err "[FAIL ] no response from /gamecontroller/toggle_playing"
            return 1
            ;;
    esac
}

show_status()
{
    echo
    echo "=========================================="
    echo " ROBIT STATUS"
    echo "=========================================="

    for name in "${SERVICES[@]}"; do
        if is_running "$name"; then
            printf "%-20s : ON\n" "$name"
        else
            printf "%-20s : OFF\n" "$name"
        fi
    done

    echo "=========================================="
}

case "${1:-}" in
    start)
        start_all
        ;;

    stop-all)
        stop_all
        ;;

    stop-except-dhi)
        stop_except_dhi
        ;;

    toggle-dhi)
        toggle_dhi
        ;;

    toggle-play)
        toggle_play
        ;;

    status)
        show_status
        ;;

    *)
        echo "Usage:"
        echo "  $0 start"
        echo "  $0 stop-all"
        echo "  $0 stop-except-dhi"
        echo "  $0 toggle-dhi"
        echo "  $0 toggle-play"
        echo "  $0 status"
        exit 1
        ;;
esac
