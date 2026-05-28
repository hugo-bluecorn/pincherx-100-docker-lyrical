# Phase 5 — Controller container + USB pass-through, arm verification

## Goal

Replace the urdf_tutorial publisher from Phase 4 with the real
controller stack: Trossen `xs_sdk` running against a physical
PincherX-100 over the U2D2 USB-serial adapter. Verify motors detect,
`/px100/joint_states` publishes at ~100 Hz, and the arm executes a
sleep → home → sleep round-trip cleanly.

Image build and the federated two-router topology from Phase 4 are
unchanged. Phase 5 only swaps the robot container's command from
`robot_state_publisher` (Phase 4) to
`ros2 launch interbotix_xsarm_control xsarm_control.launch.py`, adds
the U2D2 device pass-through, and adds the host udev rule.

## Prerequisites

- Phase 4 done; `docker compose build` produces `px100-robot:dev`
  (~868 MB) with the Interbotix workspace built via the
  `BUILD_INTERBOTIX=true` build arg.
- PincherX-100 hardware: arm + U2D2 USB cable + 12 V 3 A power supply
  with a 5.5×2.5 mm barrel jack. EU plug shape required if you're on
  EU mains — the US plug + travel adapter combination has been
  observed to cause intermittent bus failures (see project memory
  for the EU PSU verification on 2026-05-28).
- Host udev rule for the U2D2 installed at
  `/etc/udev/rules.d/99-interbotix-udev.rules`. (If not, copy from
  the Trossen `interbotix_ros_core` source tree and reload:
  `sudo udevadm control --reload-rules && sudo udevadm trigger`.)

## Steps

### 1. Verify host-side USB

With the U2D2 plugged into a host USB port (arm power can be off):

```sh
ls /dev/ttyDXL
lsusb | grep -i "0403\|future"
cat /sys/bus/usb-serial/devices/ttyUSB0/latency_timer
```

Expect: `/dev/ttyDXL` exists, FTDI FT232H present (`0403:6014`),
`latency_timer = 1`.

### 2. Power on the arm

Connect the 12 V PSU to the arm. All 5 Dynamixel LEDs should come
up steady (not flashing).

### 3. Launch the robot container

From the project root:

```sh
docker compose up robot
```

Watch for the xs_sdk startup sequence:

```
[xs_sdk-1] [INFO] Using Interbotix X-Series Driver Version: 'v0.3.7'.
[xs_sdk-1] [INFO] Pinging all motors specified in the motor_config file. (Attempt 1/3)
[xs_sdk-1] [INFO]     Found DYNAMIXEL ID: ..., Model: 'XL430-W250', Joint Name: '...'.
... (×5 motors)
[xs_sdk-1] [INFO] Interbotix X-Series Driver is up!
[xs_sdk-1] [INFO] InterbotixRobotXS is up!
```

### 4. Verify joint_states rate (second host terminal)

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash \
  && source /root/interbotix_ws/install/setup.bash \
  && ros2 topic hz /px100/joint_states"
```

Expect: ~100 Hz, low jitter (<1 ms std dev).

### 5. Round-trip motion test

Create a connect-check script (sleep → home → sleep) and run it
from inside the container. The script uses the patched
`interbotix_xs_modules` Python API from the workspace overlay and
the venv at `/root/interbotix_ws/.venv`.

Script body (`connect_check.py`):

```python
from interbotix_common_modules.common_robot.robot import (
    robot_shutdown, robot_startup,
)
from interbotix_xs_modules.xs_robot.arm import InterbotixManipulatorXS

def main():
    bot = InterbotixManipulatorXS(
        robot_model='px100',
        group_name='arm',
        gripper_name='gripper',
    )
    robot_startup()
    bot.arm.go_to_home_pose()
    bot.arm.go_to_sleep_pose()
    robot_shutdown()

if __name__ == '__main__':
    main()
```

Copy in and run:

```sh
docker cp connect_check.py robot:/tmp/connect_check.py
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash \
  && source /root/interbotix_ws/install/setup.bash \
  && source /root/interbotix_ws/.venv/bin/activate \
  && python3 /tmp/connect_check.py"
```

Expected: ~5 seconds of motion. Arm goes to home pose (px100
right-angled ⌐ shape: upper arm vertical, forearm horizontal
forward), then to sleep pose (curled, low to the table). Exit code 0.

### 6. Clean shutdown

```sh
docker compose down
```

Unplug the arm PSU. Unplug the U2D2 if no further work this session.

## Watch-outs

- **If xs_sdk fails its first ping attempts ("no status packet" for
  all 5 motors), the motors may be in a cold-start or residual-state
  condition** rather than a code bug. Verified workaround on
  2026-05-28: probe each motor with raw pyserial + PING, or call
  `dxl_wb.torque(id, false)` on each (which writes the
  TORQUE_ENABLE register), then re-run `docker compose up robot`.
  Simplest alternative: power-cycle the arm PSU and wait 30 seconds
  before re-launching. See project memory
  `project_lyrical_docker_cold_start_quirk` for the open hypothesis
  and the planned cold-start reproduction test.
- **Dev container needs `xhost +local:docker` on the host** before
  `docker compose up`, otherwise rviz2 fails with "Authorization
  required, but no authorization protocol specified" and
  `qt.qpa.xcb: could not connect to display :0`. Re-run after each
  host reboot. (Documented in `CLAUDE.md` Graphics section.)
- **Dev container needs `libxcb-cursor0`** in its apt install for
  Qt 6.5+ to load the xcb platform plugin. Without it rviz2 aborts
  with "From 6.5.0, xcb-cursor0 or libxcb-cursor0 is needed to load
  the Qt xcb platform plugin." Added to `compose.yaml`'s dev
  `EXTRA_PKGS` arg on 2026-05-28.
- **rviz2 logs many `Could not load pixmap ... /icons/*.svg` errors**
  on Lyrical — cosmetic, non-fatal. rviz2 renders and functions
  correctly; missing icons fall back to default cursors. Likely a
  missing rviz2 asset package; not investigated yet. Safe to ignore
  for now.
- **Bad / loose power supply** has been observed to produce the same
  "no status packet" symptom but persistently (not just on first
  launch). The US-plug + EU travel adapter combination causes
  intermittent contact in the 5.5×2.5 mm barrel jack. Use an EU
  12 V 3 A PSU with a native EU plug.
- **`/dev/ttyDXL` arrives inside the container as
  `/dev/ttyUSB0`** if the host udev rule didn't create the symlink
  or Docker resolved it. The entrypoint script
  (`docker/entrypoint.sh`) creates the symlink inside the container
  as a fallback (`ln -sf /dev/ttyUSB0 /dev/ttyDXL`). xs_sdk hardcodes
  `/dev/ttyDXL`, so the symlink is required.
- **No live snapshots with USB attached** is the libvirt pattern; for
  Docker, no equivalent issue, but be aware that `docker compose down`
  cleanly stops the container without releasing the host's USB device.
  Subsequent `up` re-binds with the device still on host.

## Exit criteria

- All 5 Dynamixels detected on attempt 1/3 in xs_sdk startup log.
- `/px100/joint_states` publishes at ~100 Hz with std dev < 1 ms.
- Connect-check round-trip executes physically and exits 0.
- Clean teardown via `docker compose down`.

## Next phase

Phase 6 — pedagogical motion exercise (Lab 3 Code Example 2 adapted)
with rviz2 in the dev container watching live motion. License caveat
on the Babaiasl course (NOASSERTION non-commercial) applies — pattern
reference only.
