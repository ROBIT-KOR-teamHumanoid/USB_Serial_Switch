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
| 1 | DCD | **ALL START**: DHI 토크 확인 후 전체 노드 시작 |
| 2 | (없음) | 미사용 (신호선 없음) |
| 3 | DSR | **PLAY ↔ INIT**: gamecontroller 상태 PLAYING ↔ INITIAL 토글 |
| 4 | CTS | **ALL STOP**: 전체 노드 종료 |

- **3초 이상** 누르고 있어야 실행됩니다. 짧게 누르면 아무 일도 없습니다.
- 한 번 누를 때 한 번만 실행됩니다. 다시 실행하려면 뗐다가 다시 3초 누르세요.
- 서비스가 시작될 때 이미 눌려 있는(걸려 있는) 버튼은, 한 번 떼어질 때까지 무시합니다.
- 핀은 GND와 연결될 때 "눌림"으로 읽습니다. 모든 버튼이 GND 공통선 하나를 같이 씁니다.

> ⚠️ 1번(ALL START)은 모터 토크를 켭니다. 누르기 전에 로봇이 안전한 자세인지 확인하세요.
> 4번(ALL STOP)으로 DHI를 꺼도 **토크는 유지됩니다**(DHI가 종료할 때 토크를 일부러 끄지 않음). 힘을 빼려면 모터 전원을 끄세요.

## 파일 구성

| 파일 | 역할 |
|---|---|
| `ft232_hotkey.py` | 버튼 감시. systemd 서비스로 상시 실행 |
| `robot_manager.sh` | 노드 시작/종료/상태 관리. 버튼과 터미널 양쪽에서 사용 |
| `log_filter.awk` | 노드 로그 필터 (에러/경고만 남김, 반복 줄 요약, 에러 빨간색) |
| `ft232_pin_monitor.py` | 버튼 배선 점검용. 핀 상태를 실시간 출력 |
| `setup/` | 설치용 udev 규칙, systemd 서비스, sysctl 설정 |
| `robot_logs/` | 노드별 로그 (자동 생성, git 제외) |

## 설치 (새 로봇 PC)

이 폴더가 `~/colcon_ws/scripts`에 있다고 가정합니다. 다른 위치라면 아래 경로와 `setup/ft232-hotkey.service`의 `ExecStart` 경로를 바꾸세요.

### 1. 패키지와 권한

```bash
sudo apt install python3-serial mawk
sudo usermod -aG dialout $USER      # 시리얼 포트 접근 권한, 적용하려면 다시 로그인
chmod +x ~/colcon_ws/scripts/robot_manager.sh
```

### 2. FT232 장치 이름 고정 (udev)

버튼 박스 FT232를 항상 `/dev/FT232-HOTKEY`로 잡히게 합니다.
U2D2(다이나믹셀 통신)도 같은 FTDI 칩 계열이라, **시리얼 번호로 구분**해야 합니다.

```bash
# 버튼 박스만 꽂은 상태에서 시리얼 번호 확인
udevadm info -q property -n /dev/ttyUSB0 | grep -E 'ID_SERIAL_SHORT|ID_MODEL_ID'
```

`setup/99-ft232-hotkey.rules`의 `ID_SERIAL_SHORT` 값을 위에서 나온 값으로 바꾸고 설치합니다.

```bash
sudo cp ~/colcon_ws/scripts/setup/99-ft232-hotkey.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/FT232-HOTKEY             # 링크가 보이면 성공
```

### 3. 커널 소켓 버퍼 (필수)

비전 노드가 쓰는 Cyclone DDS 설정은 16MB 수신 버퍼를 전제로 합니다. `sysctl -w`로 올리면 **재부팅할 때 사라지니** 반드시 파일로 저장하세요.

```bash
sudo cp ~/colcon_ws/scripts/setup/60-cyclonedds.conf /etc/sysctl.d/
sudo sysctl --system
sysctl net.core.rmem_max net.core.wmem_max   # 둘 다 16777216
```

### 4. 핫키 서비스 등록

```bash
sudo cp ~/colcon_ws/scripts/setup/ft232-hotkey.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ft232-hotkey
systemctl status ft232-hotkey --no-pager
```

`User=robit`으로 실행됩니다. 계정 이름이 다르면 서비스 파일을 고치세요.

### 5. ROS 설정 맞추기

핫키 서비스는 `~/.bashrc`를 읽지 않습니다. 그래서 `robot_manager.sh` 맨 위에서 ROS 설정을 직접 지정합니다.

```bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=201
```

**`~/.bashrc`의 값과 반드시 같아야** 터미널에서 `ros2 node list` 등으로 노드가 보입니다. `.bashrc`를 바꾸면 여기도 같이 바꾸세요.

### 6. 빌드

`robot_manager.sh`는 `~/colcon_ws/install/setup.bash`를 사용합니다. 아래 패키지 변경이 포함된 상태로 빌드돼 있어야 합니다.

| 패키지 | 필요한 기능 |
|---|---|
| gamecontroller | `/gamecontroller/toggle_playing` 서비스 (3번 버튼) |
| humanoid_manipulation | `manipulation.launch.py`의 `use_rviz` 인자 |
| realsense (irc_vision) | `irc_vision.launch.py`의 `show_rate_hz` 인자, `enable_sync: True` |
| insta360_link (irc_vision) | `irc_insta360_vision.launch.py`의 `show_imshow` 인자 |

```bash
cd ~/colcon_ws && colcon build
```

### 7. 동작 확인

```bash
journalctl -u ft232-hotkey -f
```

각 버튼을 **짧게** 눌러 `BTN1 pressed` / `BTN1 released`처럼 맞는 번호가 찍히는지 확인합니다. 번호가 다르면 `ft232_hotkey.py`의 `read_states()` 매핑을 고치세요.

## robot_manager.sh 사용법

터미널에서도 직접 쓸 수 있습니다.

```bash
~/colcon_ws/scripts/robot_manager.sh <명령>
```

| 명령 | 내용 |
|---|---|
| `start` | 전체 시작 (버튼 1) |
| `stop-all` | 전체 종료, DHI 포함 (버튼 4) |
| `stop-except-dhi` | DHI만 남기고 종료 |
| `toggle-dhi` | DHI 켜기/끄기 |
| `toggle-play` | gamecontroller PLAYING ↔ INITIAL (버튼 3) |
| `status` | 노드별 ON/OFF |

### 시작 순서 (`start`)

1. **DHI**를 먼저 켜고 최대 20초 동안 로그를 봅니다.
   - `Dynamixel hardware interface activated`가 나오면 토크가 켜진 것으로 보고 계속합니다.
   - `[ERROR] ... Failed to ...`(예: 모터 전원 꺼짐 → `Failed to detect required motors`)가 나오거나, 프로세스가 죽거나, 시간이 초과되면 **DHI를 끄고 중단**합니다. 나머지 노드는 켜지 않습니다.
   - DHI가 이미 켜져 있으면 2.5초 동안 모터 읽기 에러가 새로 찍히는지 보고, 찍히면 전원이 꺼진 것으로 판단해 중단합니다.
2. 이어서 순서대로 켭니다.
   `ik_walk → realsense → manipulation → gamecontroller → motion_operator → task_planner → insta360`
3. 종료(`stop-all`)도 **켠 순서 그대로** 끕니다.

task_planner는 **매니 모드**(`mani_debug_task_planner.launch.py`, `mani_debug_mode: True`)로 띄웁니다. 공 잡기와 슛은 planner가 걷기를 멈추고 IK 정지(`ikend`)를 확인한 뒤 `activate_cmd`로 humanoid_manipulation을 구동합니다. motion_operator 모션 번호(152/154)로 돌리려면 `robot_manager.sh`의 `CMD[task_planner]`를 `irc_task_planner.launch.py`로 바꾸세요.

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
| 노드별 로그 | `tail -f ~/colcon_ws/scripts/robot_logs/<노드>.log` |
| 색 있는 로그 보기 | `less -R ~/colcon_ws/scripts/robot_logs/<노드>.log` |
| RealSense depth 상태 | `grep 'depth stream' ~/colcon_ws/scripts/robot_logs/realsense.log` |

- 노드 로그에는 **에러/경고만** 남습니다. 노드 시작·종료, DHI 활성화, `[depth stream]` 상태 줄은 예외로 남깁니다.
- 같은 줄이 반복되면 한 줄과 `... repeated N times`로 요약합니다(DHI 제외).
- 에러 줄은 빨간색으로 표시됩니다.
- 노드를 시작할 때 로그가 10MB를 넘었으면 `<노드>.log.1`로 넘기고 새로 씁니다.
- 전체 로그가 필요하면(디버깅) 필터 없이 실행하세요.
  ```bash
  ROBOT_FULL_LOG=1 ~/colcon_ws/scripts/robot_manager.sh start
  ```

## 문제 해결

| 증상 | 확인할 것 |
|---|---|
| 버튼을 눌러도 로그에 아무것도 안 찍힘 | `ls -l /dev/FT232-HOTKEY`, `systemctl status ft232-hotkey`, 배선은 아래 핀 점검 |
| 특정 버튼이 계속 눌린 상태 | `python3 ~/colcon_ws/scripts/ft232_pin_monitor.py`로 핀 확인. 버튼 걸림, GND 쇼트, 납땜 확인 |
| 터미널에서 `ros2 node list`에 노드가 안 보임 | `robot_manager.sh`의 `ROS_DOMAIN_ID`, `RMW_IMPLEMENTATION`이 `~/.bashrc`와 같은지 |
| 1번 누르면 `[ABORT] motor power off or torque enable failed` | 모터 전원, `robot_logs/dhi.log`의 `Failed to ...` 원인 |
| `[ERROR] another robot_manager.sh is still running` | 이전 명령이 60초 넘게 안 끝남. `status`로 확인 |
| `[depth stream] LOST` / `NO FRAMES` | 3번 설치 단계(소켓 버퍼), 카메라 USB 연결(USB 3), `realsense.log`의 `camera.realsense` 에러 |
| 3번 누르면 `[FAIL ] no response from /gamecontroller/toggle_playing` | gamecontroller가 실행 중인지, 서버 모드(실제 게임 컨트롤러 연결)가 아닌지 |

핀 점검 도구는 핫키 서비스가 돌고 있어도 같이 쓸 수 있습니다.

```bash
python3 ~/colcon_ws/scripts/ft232_pin_monitor.py
# 21:12:35   BTN1 DCD: off   BTN3 DSR: off   BTN4 CTS: off
```
누르는 동안 `ON`, 떼면 `off`가 정상입니다.

## 노드 추가하기

`robot_manager.sh`에서 세 곳을 고칩니다.

```bash
CMD[my_node]="ros2 launch my_pkg my.launch.py"   # 실행 명령
MATCH[my_node]="my.launch.py"                     # 실행 중 판단용 문자열 (명령줄에서 검색)
SERVICES=( dhi ... my_node )                      # 시작 순서에 추가
```
