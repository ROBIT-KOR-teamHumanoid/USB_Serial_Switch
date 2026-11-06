#!/usr/bin/env bash

# colcon_ws/script/USB_Serial_Switch/robot_manager.sh -> colcon_ws
# (ROBOT_WS=<path> overrides the workspace)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WORKSPACE="${ROBOT_WS:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
RUN_DIR="/tmp/robit_robot_manager"
LOG_DIR="$SCRIPT_DIR/robot_logs"

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

strip_color()
{
    sed -e 's/\x1b\[[0-9;]*m//g'
}

# hotkey service does not read ~/.bashrc, so match its ROS settings here:
# same domain as the terminals (~/.bashrc ROS_DOMAIN_ID), else nodes are invisible
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

# kid_rl = ros2_control_node with the DYNAMIXEL hardware plugin (torque) and
# the kid_rl RL walking controller (subscribes /master2ik, publishes /walk_stopped).
# The controller is spawned inactive; start_all activates it.
declare -A CMD
CMD[kid_rl]="ros2 launch kid_rl kid_rl.launch.py"
CMD[gamecontroller]="ros2 launch gamecontroller gamecontroller.launch.py"
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
MATCH[kid_rl]="kid_rl kid_rl.launch.py"
MATCH[gamecontroller]="gamecontroller.launch.py"
MATCH[task_planner]="task_planner.launch.py"  # matches both planner launches
MATCH[insta360]="irc_insta360_vision.launch.py"
MATCH[realsense]="irc_vision.launch.py"
MATCH[motion_operator]="motion_operator.launch.py"
MATCH[manipulation]="humanoid_manipulation manipulation.launch.py"

# start order (after kid_rl torque is on and the controller is active)
# insta360 last: nothing waits for it, task_planner re-sends /insta360_enable
# every second and treats missing /insta360 data as "not found"
SERVICES=(
    kid_rl
    realsense
    manipulation
    gamecontroller
    motion_operator
    task_planner
    insta360
)

# kid_rl.launch.py ready_pose_duration_s (controllers.yaml)
READY_POSE_S=2

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

# ros2 CLI call with the workspace sourced: ros_run <timeout sec> <command...>
ros_run()
{
    local t="$1"
    shift
    timeout "$t" bash -c "
        source /opt/ros/jazzy/setup.bash
        source '$WORKSPACE/install/setup.bash'
        $*
    "
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

    # errors/warnings only (log_filter.awk); ROBOT_FULL_LOG=1 keeps everything
    # mawk -W interactive: line by line; plain mawk holds lines until the
    # node exits, which made the kid_rl torque check time out
    local filter="mawk -W interactive -v fold=1 -f '$SCRIPT_DIR/log_filter.awk'"
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

# DYNAMIXEL hardware component lifecycle label (active / inactive / unconfigured / ...)
# A read error longer than error_timeout_ms (400 ms, e.g. motor power cut) sends the
# component to on_error: torque off, back to unconfigured, while the process stays up.
hw_state()
{
    ros_run 10 "ros2 control list_hardware_components" 2>/dev/null | strip_color | \
        awk -F'label=' '/state: id=/ {print $2; exit}' | awk '{print $1}'
}

# kid_rl controller lifecycle state (active / inactive / unconfigured / ...)
controller_state()
{
    ros_run 10 "ros2 control list_controllers" 2>/dev/null | strip_color | \
        awk '$1 == "kid_rl" {print $NF; exit}'
}

# watch the kid_rl log written after <offset>:
# on_init pings every servo (10 tries, 1 s apart, fails if motor power is off),
# activation turns torque on and logs "Dynamixel Hardware Start!"
wait_kid_rl_torque()
{
    local logfile="$1"
    local offset="$2"
    local fail="Cannot connect communication port|Dynamixel Start Fail|Failed to (initialize|load|configure|activate)"
    local new

    for _ in {1..300}; do
        new="$(tail -c +"$((offset + 1))" "$logfile" 2>/dev/null)"

        if grep -q "Dynamixel Hardware Start!" <<< "$new"; then
            return 0
        fi

        if grep -q -E "$fail" <<< "$new"; then
            grep -E "$fail" <<< "$new" | head -n 3 | err_lines
            return 1
        fi

        if ! is_running kid_rl; then
            err "        kid_rl process exited"
            return 1
        fi

        sleep 0.2
    done

    err "        timeout (60 sec)"
    return 1
}

# the spawner configures kid_rl a moment after the hardware comes up
wait_controller_loaded()
{
    local state

    for _ in {1..20}; do
        state="$(controller_state)"

        case "$state" in
            inactive|active)
                return 0
                ;;
        esac

        if ! is_running kid_rl; then
            err "        kid_rl process exited"
            return 1
        fi

        sleep 0.5
    done

    err "        kid_rl controller not loaded (state=${state:-unknown})"
    return 1
}

# inactive -> active: the robot moves from its current pose to the default pose
# (READY_POSE, ${READY_POSE_S} s) and holds it. motion_operator / manipulation /
# task_planner commands only take effect while the controller is active.
activate_controller()
{
    local logfile
    local offset

    logfile="$(log_file kid_rl)"
    offset="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"

    echo "[ACTIV] kid_rl controller -> active (robot moves to default pose)"

    ros_run 20 "ros2 control set_controller_state kid_rl active" >/dev/null 2>&1

    if [ "$(controller_state)" != "active" ]; then
        err "        kid_rl controller activation failed"
        tail -c +"$((offset + 1))" "$logfile" 2>/dev/null | grep -E "ERROR" | \
            head -n 3 | err_lines
        return 1
    fi

    sleep "$READY_POSE_S"
    echo "[READY] kid_rl active, holding default pose"
}

# enable_policy=true once after ALL START. The request is latched: while the entry
# checks fail (robot on a stand / not upright / joints off the default pose) kid_rl
# stays in SAFE_HOLD and enters POLICY_RUNNING as soon as they pass. auto_hold then
# drops to SAFE_HOLD on a zero /master2ik and re-enables on a non-zero one.
enable_policy()
{
    local logfile
    local offset

    logfile="$(log_file kid_rl)"
    offset="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"

    echo "[POLCY] enable_policy -> true"

    ros_run 15 "ros2 topic pub --once --wait-matching-subscriptions 1 \
        --max-wait-time-secs 5 /kid_rl/enable_policy std_msgs/msg/Bool '{data: true}'" \
        >/dev/null 2>&1

    for _ in {1..20}; do
        if tail -c +"$((offset + 1))" "$logfile" 2>/dev/null | \
            grep -q "enable_policy received: true"; then
            echo "[ OK  ] policy requested (walks once upright near the default pose)"
            return 0
        fi
        sleep 0.1
    done

    err "        kid_rl did not receive enable_policy"
    return 1
}

start_all()
{
    echo
    echo "=========================================="
    echo " ROBIT : ALL START"
    echo "=========================================="
    echo

    if is_running kid_rl; then
        local hw
        hw="$(hw_state)"

        if [ "$hw" != "active" ]; then
            echo "[INFO ] kid_rl running but hardware ${hw:-unknown} (motor power lost?) -> restart"
            stop_service kid_rl
        else
            echo "[KEEP ] kid_rl  (hardware active)"

            if [ "$(controller_state)" != "active" ] && ! activate_controller; then
                echo
                err "[ABORT] kid_rl controller not active"
                err "        other nodes not started"
                return 1
            fi
        fi
    fi

    if ! is_running kid_rl; then
        local logfile
        local offset

        # rotate before taking the offset, so the torque check reads the right file
        rotate_log kid_rl

        logfile="$(log_file kid_rl)"
        offset="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"

        if ! start_service kid_rl || \
            ! wait_kid_rl_torque "$logfile" "$offset"; then
            echo
            err "[ABORT] motor power off or torque enable failed"
            err "        other nodes not started"
            stop_service kid_rl
            return 1
        fi

        echo "[TORQ ] kid_rl torque on"

        if ! wait_controller_loaded || ! activate_controller; then
            echo
            err "[ABORT] kid_rl controller not active"
            err "        other nodes not started (kid_rl kept, torque on)"
            return 1
        fi
    fi

    if ! enable_policy; then
        echo
        err "[WARN ] RL policy not enabled -> robot will not walk"
        err "        run: robot_manager.sh policy-on"
    fi

    local name
    for name in "${SERVICES[@]:1}"; do
        start_service "$name"
    done

    echo
    echo "=========================================="
    echo " ALL START CHECK COMPLETE"
    echo "=========================================="
}

stop_except_kid_rl()
{
    echo
    echo "=========================================="
    echo " ROBIT : STOP EXCEPT KID_RL"
    echo "=========================================="
    echo

    # same order as start, kid_rl (first) kept
    local name
    for name in "${SERVICES[@]:1}"; do
        stop_service "$name"
    done

    echo
    echo "[KEEP ] kid_rl"
    echo
    echo "=========================================="
    echo " ONLY KID_RL REMAINS"
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
    # kid_rl disables torque on shutdown: the robot goes limp
    local name
    for name in "${SERVICES[@]}"; do
        stop_service "$name"
    done

    echo
    echo "=========================================="
    echo " ALL STOPPED"
    echo "=========================================="
}

toggle_kid_rl()
{
    echo
    echo "=========================================="
    echo " ROBIT : KID_RL TOGGLE"
    echo "=========================================="

    if is_running kid_rl; then
        echo "KID_RL : ON -> OFF (torque off)"
        stop_service kid_rl
    else
        echo "KID_RL : OFF -> ON (controller stays inactive)"
        start_service kid_rl
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
    result="$(ros_run 10 "ros2 service call /gamecontroller/toggle_playing std_srvs/srv/Trigger" \
        2>&1 | grep -o "success=.*")"

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

# enable_policy is false after start; kid_rl auto_hold only re-enables a policy it
# turned off itself, so the walking policy needs one "on" after ALL START.
# kid_rl_policy.sh enable cycles the controller (robot re-enters the default pose).
policy()
{
    local action="$1"

    echo
    echo "=========================================="
    echo " ROBIT : RL POLICY ${action^^}"
    echo "=========================================="

    if ! is_running kid_rl; then
        err "[FAIL ] kid_rl not running"
        return 1
    fi

    if ros_run 30 "bash '$WORKSPACE/src/kid_rl/scripts/kid_rl_policy.sh' $action"; then
        echo "[ OK  ] policy $action"
    else
        err "[FAIL ] policy $action"
        return 1
    fi
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

    if is_running kid_rl; then
        printf "%-20s : %s\n" "  hardware" "$(hw_state)"
        printf "%-20s : %s\n" "  controller" "$(controller_state)"
    fi

    echo "=========================================="
}

case "${1:-}" in
    start)
        start_all
        ;;

    stop-all)
        stop_all
        ;;

    stop-except-kid-rl|stop-except-dhi)
        stop_except_kid_rl
        ;;

    toggle-kid-rl|toggle-dhi)
        toggle_kid_rl
        ;;

    toggle-play)
        toggle_play
        ;;

    policy-on)
        policy enable
        ;;

    policy-off)
        policy disable
        ;;

    status)
        show_status
        ;;

    *)
        echo "Usage:"
        echo "  $0 start"
        echo "  $0 stop-all"
        echo "  $0 stop-except-kid-rl"
        echo "  $0 toggle-kid-rl"
        echo "  $0 toggle-play"
        echo "  $0 policy-on"
        echo "  $0 policy-off"
        echo "  $0 status"
        exit 1
        ;;
esac
