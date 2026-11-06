# ROBIT FT232 핫키 / robot_manager

로봇 PC에 꽂은 FT232 버튼 박스로 ROS 2 노드 전체를 켜고 끄는 도구입니다.
모니터나 키보드 없이 버튼만으로 로봇을 시작·정지하고 경기 상태를 바꿀 수 있습니다.

```
버튼 박스 ──USB──> FT232 ──> ft232_hotkey.py (systemd 서비스)
                                   │ 3초 길게 누르면
                                   ▼
                            robot_manager.sh <명령>
                                   │
                                   ▼
                     ROS 2 노드 시작/종료 (colcon_ws)
```

## 버튼

| 버튼 | FT232 핀 | 기능 (3초 길게 누르기) |
|---|---|---|
| 1 | DCD | **ALL START**: kid_rl 토크 확인 → 컨트롤러 활성화 → RL 정책 켜기 → 전체 노드 시작 |
| 2 | (없음) | 미사용 (신호선 없음) |
| 3 | DSR | **PLAY ↔ INIT**: gamecontroller 상태 PLAYING ↔ INITIAL 토글 |
| 4 | CTS | **ALL STOP**: 전체 노드 종료 |

- **3초 이상** 누르고 있어야 실행됩니다. 짧게 누르면 아무 일도 없습니다.
- 한 번 누를 때 한 번만 실행됩니다. 다시 실행하려면 뗐다가 다시 3초 누르세요.
- 서비스가 시작될 때 이미 눌려 있는(걸려 있는) 버튼은, 한 번 떼어질 때까지 무시합니다.
- 핀은 GND와 연결될 때 "눌림"으로 읽습니다. 모든 버튼이 GND 공통선 하나를 같이 씁니다.

> ⚠️ 1번(ALL START)은 모터 토크를 켜고, kid_rl 컨트롤러를 활성화해 **로봇을 기본 자세로 2초 동안 움직입니다**. 누르기 전에 로봇을 지지하고 주변을 비우세요.
> ⚠️ 4번(ALL STOP)은 kid_rl까지 끕니다. kid_rl은 종료할 때 **토크를 끄므로 로봇이 바로 힘이 빠집니다**. 로봇을 잡거나 지지한 상태에서 누르세요. 토크를 유지하려면 터미널에서 `stop-except-kid-rl`을 쓰세요.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `ft232_hotkey.py` | 버튼 감시. systemd 서비스로 상시 실행 |
| `robot_manager.sh` | 노드 시작/종료/상태 관리. 버튼과 터미널 양쪽에서 사용 |
| `log_filter.awk` | 노드 로그 필터 (에러/경고만 남김, 반복 줄 요약, 에러 빨간색) |
| `ft232_pin_monitor.py` | 버튼 배선 점검용. 핀 상태를 실시간 출력 |
| `setup/` | 설치용 udev 규칙, systemd 서비스 |
| `robot_logs/` | 노드별 로그 (자동 생성, git 제외) |

## 설치 (새 로봇 PC)

이 폴더가 `~/colcon_ws/script/USB_Serial_Switch`에 있다고 가정합니다. `robot_manager.sh`는 두 단계 위 폴더를 워크스페이스로 씁니다(`ROBOT_WS=<경로>`로 바꿀 수 있음). 다른 위치라면 아래 경로와 `setup/ft232-hotkey.service`의 `ExecStart` 경로를 바꾸세요.

### 1. 패키지와 권한

```bash
sudo apt install python3-serial mawk
sudo usermod -aG dialout $USER      # 시리얼 포트 접근 권한, 적용하려면 다시 로그인
chmod +x ~/colcon_ws/script/USB_Serial_Switch/robot_manager.sh
```

### 2. FT232 장치 이름 고정 (udev)

버튼 박스 FT232를 항상 `/dev/FT232-HOTKEY`로 잡히게 합니다.
U2D2(다이나믹셀 통신, `0403:6014`)와 EBIMU(`0403:6015`)도 같은 FTDI 계열이라, 모델 ID `6001`과 **시리얼 번호로 구분**합니다.

```bash
# ID_MODEL_ID=6001 인 포트의 시리얼 번호 확인
for d in /dev/ttyUSB[0-9]*; do echo "$d: $(udevadm info -q property -n $d | grep -E 'ID_SERIAL_SHORT|ID_MODEL_ID' | tr '\n' ' ')"; done
```

`setup/99-ft232-hotkey.rules`의 `ID_SERIAL_SHORT` 값을 위에서 나온 값으로 바꾸고 설치합니다.

```bash
sudo cp ~/colcon_ws/script/USB_Serial_Switch/setup/99-ft232-hotkey.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/FT232-HOTKEY             # 링크가 보이면 성공
```

### 3. 핫키 서비스 등록

```bash
sudo cp ~/colcon_ws/script/USB_Serial_Switch/setup/ft232-hotkey.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ft232-hotkey
systemctl status ft232-hotkey --no-pager
```

`User=robit`으로 실행됩니다. 계정 이름이 다르면 서비스 파일을 고치세요.

### 4. ROS 설정 맞추기

핫키 서비스는 `~/.bashrc`를 읽지 않습니다. 그래서 `robot_manager.sh` 맨 위에서 ROS 설정을 직접 지정합니다.

```bash
export ROS_DOMAIN_ID=201
```

**`~/.bashrc`의 값과 반드시 같아야** 터미널에서 `ros2 node list` 등으로 노드가 보입니다. `.bashrc`를 바꾸면 여기도 같이 바꾸세요.

### 5. 빌드

`robot_manager.sh`는 `~/colcon_ws/install/setup.bash`를 사용합니다. 아래 패키지 변경이 포함된 상태로 빌드돼 있어야 합니다.

| 패키지 | 필요한 기능 |
|---|---|
| gamecontroller | `/gamecontroller/toggle_playing` 서비스 (3번 버튼) |
| humanoid_manipulation | `manipulation.launch.py`의 `use_rviz` 인자 |
| kid_rl | `kid_rl.launch.py` (DYNAMIXEL 하드웨어 + RL 보행 컨트롤러), `scripts/kid_rl_policy.sh` |
| realsense (irc_vision) | `irc_vision.launch.py`의 `show_rate_hz` 인자, `enable_sync: True` |
| insta360_link (irc_vision) | `irc_insta360_vision.launch.py`의 `show_imshow` 인자 |

```bash
cd ~/colcon_ws && colcon build
```

### 6. 동작 확인

```bash
journalctl -u ft232-hotkey -f
```

각 버튼을 **짧게** 눌러 `BTN1 pressed` / `BTN1 released`처럼 맞는 번호가 찍히는지 확인합니다. 번호가 다르면 `ft232_hotkey.py`의 `read_states()` 매핑을 고치세요.

## robot_manager.sh 사용법

터미널에서도 직접 쓸 수 있습니다.

```bash
~/colcon_ws/script/USB_Serial_Switch/robot_manager.sh <명령>
```

| 명령 | 내용 |
|---|---|
| `start` | 전체 시작 (버튼 1) |
| `stop-all` | 전체 종료, kid_rl 포함 → 토크 꺼짐 (버튼 4) |
| `stop-except-kid-rl` | kid_rl만 남기고 종료, 토크 유지 (예전 이름 `stop-except-dhi`도 됨) |
| `toggle-kid-rl` | kid_rl 켜기/끄기. 켤 때 컨트롤러는 inactive로 둠 (예전 이름 `toggle-dhi`도 됨) |
| `toggle-play` | gamecontroller PLAYING ↔ INITIAL (버튼 3) |
| `policy-on` | RL 보행 정책 켜기 (`kid_rl_policy.sh enable`, 컨트롤러를 다시 활성화해 기본 자세를 거침) |
| `policy-off` | RL 보행 정책 끄기 |
| `status` | 노드별 ON/OFF, kid_rl 하드웨어·컨트롤러 상태 |

### 시작 순서 (`start`)

1. **kid_rl**(`ros2 launch kid_rl kid_rl.launch.py`)을 먼저 켜고 최대 60초 동안 로그를 봅니다.
   - `Dynamixel Hardware Start!`가 나오면 토크가 켜진 것으로 보고 계속합니다.
   - `Cannot connect communication port`(모터 전원 꺼짐, 서보마다 10초 재시도), `Dynamixel Start Fail`, `Failed to initialize/load/configure/activate`가 나오거나, 프로세스가 죽거나, 시간이 초과되면 **kid_rl을 끄고 중단**합니다. 나머지 노드는 켜지 않습니다.
2. spawner가 `kid_rl` 컨트롤러를 inactive로 올릴 때까지 기다린 뒤 `ros2 control set_controller_state kid_rl active`로 활성화합니다. 로봇이 기본 자세로 2초 동안 움직입니다. 활성화가 실패하면(예: IMU 없음 → `Could not start IMU`) 중단하고, kid_rl은 토크를 켠 채로 둡니다.
   - kid_rl이 이미 켜져 있으면 `ros2 control list_hardware_components`로 하드웨어 상태를 봅니다. `active`가 아니면(동작 중 모터 전원이 끊기면 400 ms 뒤 토크를 끄고 unconfigured가 됨) kid_rl을 재시작합니다. 컨트롤러만 inactive면 활성화만 합니다.
3. `/kid_rl/enable_policy`에 `true`를 한 번 보내 **RL 보행 정책을 켭니다**. kid_rl 로그에 `enable_policy received: true`가 찍히면 성공입니다. 실패하면 빨간 경고만 찍고 나머지 노드는 그대로 켭니다(그때는 `policy-on`).
   - 요청은 유지됩니다. 로봇이 지지대에 걸려 있거나 기울어져 있거나 관절이 기본 자세에서 벗어나 있으면 SAFE_HOLD로 기다리다가, **조건이 맞는 순간 정책이 시작됩니다**. 바닥에 내려놓을 때 주의하세요.
   - 그 뒤로는 auto_hold가 처리합니다. task_planner가 `/master2ik`로 0을 보내면 정책을 내리고(모션/매니 가능), 0이 아닌 속도를 보내면 다시 켜서 걷습니다.
4. 이어서 순서대로 켭니다.
   `realsense → manipulation → gamecontroller → motion_operator → task_planner → insta360`
5. 종료(`stop-all`)도 **켠 순서 그대로** 끕니다.

task_planner는 **매니 모드**(`mani_debug_task_planner.launch.py`, `mani_debug_mode: True`)로 띄웁니다. 공 잡기와 슛은 planner가 걷기를 멈추고 kid_rl의 `/walk_stopped`가 true가 되는 것을 확인한 뒤 `activate_cmd`로 humanoid_manipulation을 구동합니다. motion_operator 모션 번호(152/154)로 돌리려면 `robot_manager.sh`의 `CMD[task_planner]`를 `irc_task_planner.launch.py`로 바꾸세요.

### 동작 세부

- **동시 실행 방지:** `status`를 뺀 명령은 잠금을 잡고 하나씩 실행합니다. 다른 명령이 실행 중이면 최대 60초 기다립니다.
- **종료:** SIGINT → (3초) SIGTERM → (2초) SIGKILL 순서로 프로세스 그룹 전체를 끕니다.
- **RealSense 재시작 대기:** 끈 지 5초가 안 됐으면 기다렸다가 켭니다. 바로 다시 열면 카메라가 USB에서 끊기는 문제가 있었습니다.
- **화면 없는 환경:** `DISPLAY`가 없으면(핫키 서비스) Qt를 `offscreen`으로 띄워 gamecontroller가 죽지 않게 하고, 비전 디버그 창(`show_rate_hz:=0.0`, `show_imshow:=false`)과 manipulation의 rviz를 끕니다.
- **PID 파일:** `/tmp/robit_robot_manager/` (재부팅하면 지워짐)

## 로그

| 보고 싶은 것 | 명령 |
|---|---|
| 버튼 입력, 명령 결과 | `journalctl -u ft232-hotkey -f` |
| 노드별 로그 | `tail -f ~/colcon_ws/script/USB_Serial_Switch/robot_logs/<노드>.log` |
| 색 있는 로그 보기 | `less -R ~/colcon_ws/script/USB_Serial_Switch/robot_logs/<노드>.log` |
| RealSense depth 상태 | `grep 'depth stream' ~/colcon_ws/script/USB_Serial_Switch/robot_logs/realsense.log` |

- 노드 로그에는 **에러/경고만** 남습니다. 노드 시작·종료, `Dynamixel Hardware Start!/Stop!`, kid_rl의 `enable_policy received`·`Mode A -> B` 전환, `[depth stream]` 상태 줄은 예외로 남깁니다.
- 같은 줄이 반복되면 한 줄과 `... repeated N times`로 요약합니다.
- 에러 줄은 빨간색으로 표시됩니다.
- 노드를 시작할 때 로그가 10MB를 넘었으면 `<노드>.log.1`로 넘기고 새로 씁니다.
- 전체 로그가 필요하면(디버깅) 필터 없이 실행하세요.
  ```bash
  ROBOT_FULL_LOG=1 ~/colcon_ws/script/USB_Serial_Switch/robot_manager.sh start
  ```

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| 버튼을 눌러도 로그에 아무것도 안 찍힘 | `ls -l /dev/FT232-HOTKEY`, `systemctl status ft232-hotkey`, 배선은 아래 핀 점검 |
| 특정 버튼이 계속 눌린 상태 | `python3 ~/colcon_ws/script/USB_Serial_Switch/ft232_pin_monitor.py`로 핀 확인. 버튼 걸림, GND 쇼트, 납땜 확인 |
| 터미널에서 `ros2 node list`에 노드가 안 보임 | `robot_manager.sh`의 `ROS_DOMAIN_ID`가 `~/.bashrc`와 같은지 |
| 1번 누르면 `[ABORT] motor power off or torque enable failed` | 모터 전원, U2D2 연결(`/dev/ttyUSB-U2D2`), `robot_logs/kid_rl.log`의 에러 |
| 1번 누르면 `[ABORT] kid_rl controller not active` | `robot_logs/kid_rl.log`의 에러 (IMU `/dev/ttyUSB-EBIMU`, joint state 읽기) |
| 걷기 명령을 보내도 서 있기만 함 | `kid_rl.log`에 `enable_policy received: true`가 있는지(없으면 `policy-on`), `Policy requested but entry checks failed` 경고(자세/IMU), `Mode ... -> FAULT` 여부 |
| `[ERROR] another robot_manager.sh is still running` | 이전 명령이 60초 넘게 안 끝남. `status`로 확인 |
| `[depth stream] LOST` / `NO FRAMES` | 카메라 USB 연결(USB 3), `realsense.log`의 `camera.realsense` 에러 |
| 3번 누르면 `[FAIL ] no response from /gamecontroller/toggle_playing` | gamecontroller가 실행 중인지, 서버 모드(실제 게임 컨트롤러 연결)가 아닌지 |

핀 점검 도구는 핫키 서비스가 돌고 있어도 같이 쓸 수 있습니다.

```bash
python3 ~/colcon_ws/script/USB_Serial_Switch/ft232_pin_monitor.py
# 21:12:35   BTN1 DCD: off   BTN3 DSR: off   BTN4 CTS: off
```
누르는 동안 `ON`, 떼면 `off`가 정상입니다.

## 노드 추가하기

`robot_manager.sh`에서 세 곳을 고칩니다.

```bash
CMD[my_node]="ros2 launch my_pkg my.launch.py"   # 실행 명령
MATCH[my_node]="my.launch.py"                     # 실행 중 판단용 문자열 (명령줄에서 검색)
SERVICES=( kid_rl ... my_node )                      # 시작 순서에 추가
```
