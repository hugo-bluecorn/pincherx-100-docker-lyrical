# Phase 6 — Pedagogical motion exercise (Babaiasl Labs 3-9 walkthrough)

Walk a student sequentially through every robot-driving exercise in
Babaiasl's *Modern Robotics* course wiki, Labs 3-9, against this
project's px100 + Lyrical Docker setup. Pedagogical only. The
arm-control plumbing is already verified end-to-end in
[Phase 5](05-controller-usb-verification.md); this phase is about
using that plumbing to learn the X-series Python API and the math
the course teaches.

This document is designed to stand on its own: a student who has
finished Phase 5 should be able to land here, follow the order
below, and get an exposure to the API surface that is substantive
enough to be useful for [Phase 7](07-flutter-client-over-lan.md)
and for the post-runbook Bluecorn work. The walkthrough does **not**
ask the student to commit any per-lab scripts or to tag a
verification image — Phase 5's tagged controller image remains the
working state through Phase 7.

## Attribution and license

- Course: **Babaiasl, M.** *Modern Robotics with the PincherX-100.*
  Saint Louis University.
  Wiki: <https://github.com/madibabaiasl/modern-robotics-course/wiki>
- Local clone (cloned 2026-05-28): wiki at
  `git/modern-robotics-course/wiki/` next to this repo.
- Course license: **NOASSERTION non-commercial**. Verbatim text at
  <https://github.com/madibabaiasl/modern-robotics-course/blob/main/License>:
  "Permission is granted to use, copy, and modify this repository
  for non-commercial purposes only. Commercial use, including use
  in products or services for profit, is prohibited without prior
  written permission."
- This walkthrough is Apache-2.0 (matches the rest of this runbook).
  It adapts the *API-usage pattern* of the course's exercises —
  high-level `InterbotixManipulatorXS` calls that are themselves
  documented Trossen public API, not authored work unique to the
  course. The course's prose, math derivations, fill-in-the-blank
  skeletons, and project solutions remain encumbered by the
  non-commercial constraint and must not be bundled into a shipped
  product (e.g. Bluecorn). When in doubt, link out to the wiki
  rather than copy.

## How to use this walkthrough

Goal per lab below is exposure to one slice of the X-series API or
to one concept in the underlying math. There is no "pass/fail";
the student is encouraged to read the course wiki section linked
at the top of each lab, do the math the course asks for, and then
run the code variation here.

### Pre-operation checklist

Assume you have just powered on the laptop, logged in, and opened a
single terminal. Work through Sections A → F in order. Each step has a
verify command and a fallback if it fails. Phases 1-5 of this runbook
must already be done — those are *not* part of this checklist.

**Terminology**: "terminal 1" = the terminal where you run the warmup
script and `docker compose up` (the latter holds the terminal for the
whole session); "terminal 2" = the lab-work terminal you'll open
later. Open terminal 2 only after Section D succeeds.

#### A. Host-side software state

Run all of these in terminal 1. Steps A.1, A.2, A.3 are one-time per
host install (verify only). A.4 and A.6 are per-reboot. A.5 is
one-time per host.

**A.1 — Docker daemon is running.**

```sh
docker info >/dev/null && echo OK
```

Expect: `OK`. If "Cannot connect to the Docker daemon": start it with
`sudo systemctl start docker`, then re-run.

**A.2 — Your user can run docker without sudo.**

```sh
docker run --rm hello-world
```

Expect: a "Hello from Docker!" banner. If "permission denied while
trying to connect to the Docker daemon socket": you're not in the
`docker` group. See [Phase 1](01-host-preparation.md). Newly-added
group membership requires logout/login.

**A.3 — Phase 5 images exist locally.**

```sh
docker image ls | grep ^px100-
```

Expect two lines: `px100-robot:dev` and `px100-dev:dev`. If missing,
build them now (~5-10 min the first time):

```sh
cd <path-to>/pincherx-100-docker-lyrical
docker compose build
```

**A.4 — No stale containers from a prior session.**

```sh
cd <path-to>/pincherx-100-docker-lyrical && docker compose ps
```

Expect: empty output (or only headers). If anything is "running" or
"exited", tear it down: `docker compose down`.

**A.5 — Host udev rule installed for the U2D2.**

```sh
ls /etc/udev/rules.d/99-interbotix-udev.rules
```

Expect: the file exists. If missing, see
[Phase 5 Step 1](05-controller-usb-verification.md). One-time per
host install.

**A.6 — XWayland access granted to Docker containers (per reboot).**

```sh
xhost +local:docker
```

Expect: `non-network local connections being added to access control
list`. Re-run after each host reboot — the grant is not persistent.
Without this, rviz2 in the dev container fails with "Authorization
required" / "qt.qpa.xcb: could not connect to display".

**A.7 — Lab scripts directory on the host (one-time).**

```sh
mkdir -p ~/px100-lab-scripts
```

This is where lab scripts live before they're copied into the `robot`
container.

#### B. Physical arm setup

1. **Arm fixed to a stable surface** with **~40 cm of clear workspace
   in front**. Nothing under the EE drop path.
2. **Arm PSU**: 12 V 3 A PSU connected to the arm's barrel jack
   (5.5×2.5 mm) AND plugged into a wall outlet. Per
   [Phase 5 watch-outs](05-controller-usb-verification.md), use an EU
   plug if you're on EU mains — the US-plug + EU-adapter combination
   has caused intermittent bus failures.
3. **U2D2 USB cable plugged into a host USB port** (any port; xHCI is
   host-side).
4. **Power on the arm**. All 5 Dynamixel LEDs should come up **steady,
   not flashing**. Flashing usually indicates a PSU contact problem;
   power cycle and re-check.
5. **A hand near the arm power source** (rocker, barrel-jack, or wall
   plug), ready to kill power if motion looks wrong.

**B.6 — Verify the host sees the U2D2.**

```sh
ls /dev/ttyDXL
```

Expect: `/dev/ttyDXL`. If missing: the U2D2 isn't plugged in, the
udev rule didn't fire, or the symlink hasn't been created. Replug;
if still missing, see
[Phase 5 Step 1 watch-outs](05-controller-usb-verification.md).

#### C. Warm the U2D2 (cold-start initialization)

Still in terminal 1, in the project root, run the arm-warmup script:

```sh
./scripts/arm-warmup.sh
```

The script tears down any residual containers, starts `robot`
detached, sends one raw Protocol-2.0 PING per motor to settle the
U2D2's RS-485 direction-switching, prints a 5-line `ID N: OK (14
bytes)` report, and tears down. Total runtime ~10 s.

Expect a final line `OK — all 5 motors responded. The arm is warm.`
If the script prints `FAIL` instead, follow its error message —
usually the PSU contact, the U2D2 cable, or the udev rule.

**Why this step exists.** `xs_sdk` uses DynamixelWorkbench's
P1.0-before-P2.0 ping pattern. On a cold U2D2 (freshly plugged in
or power-cycled), the first half-duplex direction switches are
unreliable; the P1.0 attempts taint the immediately-following P2.0
RX, and `xs_sdk` reports `0/5 motors found` and FATAL-exits. The
image entrypoint includes a `dynamixel_sdk`-based warmup but it's
not reliable in all timing conditions. The host-side `arm-warmup.sh`
uses the verified raw-pyserial approach and runs after the
entrypoint completes — when the device is definitely ready inside
the container. See `runbook/05-controller-usb-verification.md`
watch-outs and project memory `project_lyrical_docker_cold_start_quirk`.

If the arm has been on continuously since an earlier session within
the same boot, this step is optional — warm-arm `down` / `up`
cycles don't trigger the cold-start failure. But it's safe to run
always, and adds ~10 s to session start.

#### D. Bring up the Docker stack

Still in terminal 1:

```sh
docker compose up
```

This brings up both containers. Watch the log for these milestones,
in order:

1. `[xs_sdk-1] Pinging all motors specified in the motor_config file.
   (Attempt 1/3)`
2. `[xs_sdk-1] Found DYNAMIXEL ID: X` lines, **5 total** (waist,
   shoulder, elbow, wrist_angle, gripper).
3. `[xs_sdk-1] Interbotix X-Series Driver is up!`
4. `[xs_sdk-1] InterbotixRobotXS is up!`
5. **rviz2 window appears** (XWayland), showing the px100 URDF
   tracking the live arm pose.

If you ever see `0/5 motors found` despite having run the warmup
script in Section C, power-cycle the arm, wait ~10 s, and re-run
`./scripts/arm-warmup.sh` before retrying `docker compose up`.

Leave `docker compose up` running in terminal 1 for the rest of the
session.

#### E. Verify the stack is healthy

Open a second terminal (terminal 2) — the lab-work terminal. In it:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && timeout 5 ros2 topic hz /px100/joint_states"
```

Expect: rate ~100 Hz, std dev < 1 ms after 5 seconds. If the topic is
silent or under 50 Hz, `xs_sdk` is degraded — check terminal 1's
log, then go back to Section C (warmup) and Section D (compose up).

#### F. Configure rviz for the first time

The rviz2 window from Section D opens with rviz's **default** config,
which doesn't match this project. You'll see an empty 3D viewport and
a red `Global Status: Error — Frame [map] does not exist` in the
Displays panel. **The arm is publishing TF correctly — rviz just
doesn't know where to look.** Fix in three clicks:

**F.1 — Fix the Fixed Frame.**

In the `Displays` panel on the left, under `Global Options`, click the
value next to `Fixed Frame` (currently `map`). Change it to:

```
world
```

Press Enter. The `Global Status` line turns from red to green.

**F.2 — Add a RobotModel display.**

Click the `Add` button at the bottom of the `Displays` panel. In the
dialog, scroll to `rviz_default_plugins` → select `RobotModel` →
click `OK`.

A new `RobotModel` entry appears in the Displays panel. Its initial
status will likely be red because the default `Description Topic` is
`/robot_description`, but in our setup the topic is namespaced.
Expand the `RobotModel` entry, find the `Description Topic` property,
and change it to:

```
/px100/robot_description
```

The Topic sub-status turns green (`1 messages received at ~30 Hz`)
and every link shows `Transform OK`. **However, the URDF sub-status
remains red with `Errors loading geometries`.** This is a known
limitation of the current image split: the dev container is built
from `osrf/ros:lyrical-desktop-full-resolute` *without* the
Interbotix workspace overlay (the workspace lives in the robot
container only, per the image entrypoint design). The URDF
references mesh files via `package://interbotix_xsarm_descriptions/
meshes/...` URIs, and rviz resolves those via the local
`ament_index` — which doesn't include `interbotix_xsarm_descriptions`
in dev. Mesh geometries don't render; the 3D viewport stays empty.

Joint state telemetry, TF tracking, and arm motion all work fine —
it's *only* the URDF visual mesh that fails to load. For now the
workaround is **F.3 — add a TF display**, which gives you live axes
triads to see motion. Proper fix (planned follow-up): either build
the interbotix workspace in the dev image too, or share the robot's
`install/` dir between containers via a named volume.

**F.3 — Add a TF display (effectively required given F.2's mesh
limitation).**

Click `Add` again → `rviz_default_plugins` → `TF` → `OK`. Tiny RGB
axes triads appear at every joint frame: base, shoulder, elbow,
wrist, gripper bar, fingers, EE. When the arm moves, the triads
move with it — this is your visual feedback for motion in lieu of
the mesh model. Also useful for understanding the forward-kinematics
math in Labs 7 and 9.

**F.4 — Hiding individual links and frames (used by Labs 5, 7, 9).**

Three of the labs ask you to *"hide frames in RViz from the left-hand
side panel"* to isolate the base frame and end-effector frame for a
diagram or screenshot. The course doesn't say *how*. Two mechanisms:

- **Hide the visual mesh of a robot link** (e.g. hide the shoulder
  link's 3D model): expand the `RobotModel` entry in the Displays
  panel → expand `Links` → each link has a checkbox next to its name.
  Uncheck a link to hide its visual mesh; check it to show.
- **Hide a TF axes triad** (e.g. hide the elbow's RGB axes): expand
  the `TF` entry → expand `Frames` → each frame has a checkbox.
  Uncheck to hide.

For the Lab 7 / Lab 9 "base frame + end-effector frame only" view,
uncheck every TF frame except `world`, `px100/base_link`, and
`px100/ee_gripper_link` (or `px100/ee_arm_link` if you prefer the
arm-side end-effector frame). For Lab 5's "selectively hide frames"
note, hide whatever clutters the comparison you're making against
your matplotlib plot.

**F.5 — (Optional) Save the config inside the container.**

`File` → `Save Config As` → save to `/root/.rviz2/default.rviz`.
This persists until the next `docker compose down` (the dev
container is removed on teardown). **For a persistent config across
sessions**, the cleanest fix is to bind-mount a host directory into
`/root/.rviz2/` in `compose.yaml` — that's a follow-up improvement,
not blocking for Phase 6.

In practice, F.1 + F.2 take ~10 seconds and are quick to redo each
session.

You are now ready to proceed to the labs below.

### How each lab run works

The pattern is the same every time:

1. Create or edit the script on the host with `nano`.
2. Copy it into the `robot` container with `docker cp`.
3. Run it inside the `robot` container with `docker exec`, sourcing
   ROS env + the Interbotix workspace overlay + the venv first.

The `docker exec` invocation is verbose — the entrypoint
pre-sources everything for the *foreground command*, but
`docker exec` bypasses the entrypoint. So each run sources
explicitly. Optional helper at the bottom of this doc (Extras)
wraps it in a shell function.

---

## Lab 3 — Python-ROS API and a simple pick-and-place

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-3:-Working-with-Python‐ROS-API-and-a-Simple-Pick‐and‐Place-Task>

Lab 3 is the entry point for the Python-ROS API and is reused by
Labs 4, 5, and 9 as the "experimentally verify your math by
commanding these joint angles" tool. There are two code examples.

### Lab 3 Code Example 1 — joint position control

Drives individual joint angles. The course gives a skeleton with
`joint_positions = [joint1, joint2, joint3, joint4]` and asks the
student to fill in values **within the joint limits from Lab 1**:

| Joint        | Approx. range (rad) | Approx. range (deg) |
|--------------|---------------------|---------------------|
| waist        | -π   to +π          | -180° to +180°      |
| shoulder     | -1.85 to +1.91      | -106° to +109°      |
| elbow        | -1.76 to +1.61      | -101° to  +92°      |
| wrist_angle  | -1.74 to +2.14      | -100° to +123°      |

(Source of truth for limits: `px100.yaml` in the patched Trossen
workspace inside the `robot` image; mirrors the upstream
`interbotix_xsarm_control/config/px100.yaml`.)

Write the script once, then invoke with the four angles each lab
asks for. On the host:

```sh
nano ~/px100-lab-scripts/lab3_joint_control.py
```

Paste:

```python
#!/usr/bin/env python3
"""
Lab 3 Code Example 1 (parametric) — single-arm joint position control.

Adapts the API-usage pattern from:
    Babaiasl, M. *Modern Robotics with the PincherX-100*.
    Saint Louis University. NOASSERTION non-commercial.
    https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-3

Pre-flight:
- `docker compose up` is running with robot + dev containers up
- ROS env + Interbotix workspace + venv are sourced (the docker
  exec wrapper in the runbook handles this)

Usage:
    python3 lab3_joint_control.py <waist> <shoulder> <elbow> <wrist_angle>

Angles in radians. See the joint-limit table in the walkthrough.

Sequence:
    home pose -> commanded angles -> home pose -> sleep pose
"""

import sys

from interbotix_common_modules.common_robot.robot import (
    robot_shutdown,
    robot_startup,
)
from interbotix_xs_modules.xs_robot.arm import InterbotixManipulatorXS


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(2)
    joint_positions = [float(a) for a in sys.argv[1:5]]

    bot = InterbotixManipulatorXS(
        robot_model='px100',
        group_name='arm',
        gripper_name='gripper',
    )

    robot_startup()
    bot.arm.go_to_home_pose()
    bot.arm.set_joint_positions(joint_positions)
    bot.arm.go_to_home_pose()
    bot.arm.go_to_sleep_pose()
    robot_shutdown()


if __name__ == '__main__':
    main()
```

Save (Ctrl-O, Enter, Ctrl-X). Then copy into the container and
run with a starting set of angles well inside the limits:

```sh
docker cp ~/px100-lab-scripts/lab3_joint_control.py robot:/root/lab3_joint_control.py
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.5 -0.5 0.5 0.0"
```

Watch the physical arm move and the URDF in rviz2 (in the `dev`
container window) track it in real time.

**Note on `bot.shutdown()` vs our pattern.** The course's example
uses `bot.shutdown()` directly. This walkthrough uses
`robot_startup()` / `robot_shutdown()` from
`interbotix_common_modules.common_robot.robot` instead — same
pattern as Phase 5's `connect_check.py`, which is more explicit
about the node lifecycle. Both styles work; stay consistent within
your own scripts.

### Lab 3 Code Example 2 — simple pick-and-place

Adds Cartesian-space displacement and gripper pressure to the API
surface. The course's example commands waist 90°, then drops the
EE 10 cm, retracts 20 cm, grasps, lifts, raises gripper pressure,
releases, and returns to sleep — a mimed pick-and-place with no
perception.

`set_ee_cartesian_trajectory` accepts `x`, `y`, `z`, `roll`,
`pitch`, `yaw`. The px100 is **4-DOF**: the IK gate inside
`arm.py` short-circuits with a warn-level log and returns `False`
if you pass non-zero `y` or `yaw`. Stick to `x`, `z`, `roll`,
`pitch`.

Write the script on the host:

```sh
nano ~/px100-lab-scripts/lab3_pick_and_place.py
```

Paste:

```python
#!/usr/bin/env python3
"""
Lab 3 Code Example 2 — simple pick-and-place (no perception).

Adapts the API-usage pattern from Babaiasl Lab 3
(NOASSERTION non-commercial; see walkthrough header).

Pre-flight:
- `docker compose up` is running with robot + dev containers up
- ROS env + Interbotix workspace + venv are sourced

Sequence:
    home -> waist 90 deg -> EE z=-0.1 -> EE x=-0.2 ->
    grasp -> EE z=+0.1 -> raise gripper pressure -> release ->
    home -> sleep
"""

import numpy as np

from interbotix_common_modules.common_robot.robot import (
    robot_shutdown,
    robot_startup,
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
    bot.arm.set_single_joint_position(joint_name='waist', position=np.pi/2.0)
    bot.arm.set_ee_cartesian_trajectory(z=-0.1)
    bot.arm.set_ee_cartesian_trajectory(x=-0.2)
    bot.gripper.grasp(2.0)
    bot.arm.set_ee_cartesian_trajectory(z=0.1)
    bot.gripper.set_pressure(1.0)
    bot.gripper.release(2.0)
    bot.arm.go_to_home_pose()
    bot.arm.go_to_sleep_pose()

    robot_shutdown()


if __name__ == '__main__':
    main()
```

Copy in and run:

```sh
docker cp ~/px100-lab-scripts/lab3_pick_and_place.py robot:/root/lab3_pick_and_place.py
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_pick_and_place.py"
```

Expected motion: home → waist swings to side → EE descends → EE
retracts toward the base → audible gripper close (2 s hold) → EE
lifts → audible gripper open (now at max pressure — visibly more
forceful than the first close) → home → sleep. About 18 s total
with default `moving_time=2.0`.

**px100-specific:** the `set_pressure(1.0)` call sets the gripper
PWM to its upper limit. If grip force feels weak even at 1.0,
check that the gripper's operating mode is `pwm` via
`docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && ros2 service call /px100/get_robot_info ..."`.

**Watch out — IK failure on tight Cartesian sequences:** the
course's `(z=-0.1, x=-0.2)` chain is genuinely tight. After
`waist=π/2` + `z=-0.1`, the EE is at the same height as the
shoulder pivot (`z=0.0931` per the px100 mr_descriptions), and the
subsequent `x=-0.2` retraction would put the EE just ~49 mm from
the shoulder — near a singular fold where the IK solver struggles.
**Verified workable on the project arm 2026-05-28:** `x=-0.1`
(EE ends ~149 mm from the shoulder, comfortably reachable). Adapt
your delta until the call succeeds; the pedagogical point of Lab 3
is that the student tunes the trajectory to their arm's reach.

**Watch out — `.warn` → `.warning` on Lyrical:** Lyrical's `rclpy`
removed the deprecated `.warn()` logger alias; only `.warning()`
exists. The `interbotix_xs_modules` Python API (in our forked
workspace at the time of writing) still calls `.warn()` in five
places in `xs_robot/arm.py` — including the IK-failure path in
`set_ee_pose_matrix`. Result: a Cartesian-IK miss that *should*
log a warning and let the call return `False` instead crashes the
script with `AttributeError: 'RcutilsLogger' object has no
attribute 'warn'`. Workaround until the patch lands: keep your
Cartesian deltas modest so IK doesn't fail. (Patch tracked as a
follow-up to the [[project_lyrical_port_patches]] inventory.)

**Watch out — gripper-state assumption:** the course's recipe
assumes the gripper is *open* before `grasp(2.0)` is called. If a
previous run (or hand manipulation) left the gripper closed,
`grasp(2.0)` is a no-op — `gripper_controller` skips publishing
when the gripper is already at its commanded-direction limit. To
make the script reproducible across re-runs, insert a leading
`bot.gripper.release(2.0)` right after `go_to_home_pose()`. The
course doesn't include this; it's a pragmatic adaptation for
replay.

---

## Lab 4 — DOFs and joint types

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-4:-Exploring-DOFs-and-Joint-Types-in-the-PincherX-100-Robot-Arm-plus-DOFs-Practice-Questions>

Mostly theory: Grübler's formula on the px100, joint-type
identification, practice questions. The single robot-driving step
is **Step 3** — use the joint control code from Lab 3 to
demonstrate that the arm has the expected number of DOFs
(excluding the gripper).

Pick four angles, one per joint, that each visibly exercise that
joint and no other. Each run uses the same script copied in Lab 3
Example 1 (`/root/lab3_joint_control.py` inside the container is
already in place):

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.5 0.0 0.0 0.0"
```

Then:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.0 -0.5 0.0 0.0"
```

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.0 0.0 0.5 0.0"
```

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.0 0.0 0.0 0.5"
```

Each run returns the arm to home and then sleep, so the next run
starts from a known pose. Show that all four joints are
independently actuable — that's your hands-on confirmation of
4-DOF.

(See Extras at the bottom for a shell function that cuts this
boilerplate down to `rosexec python3 /root/lab3_joint_control.py
0.5 0.0 0.0 0.0`.)

---

## Lab 5 — Tool orientation using rotation matrices

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-5:-Tool-Orientation-of-PincherX-100-Robot-Arm-Using-Rotation-Matrices>

Mostly off-arm: hand-derive the rotation matrices for the px100's
zero pose, compose them with NumPy, and visualize the resulting
tool frame with matplotlib. The course expects you to do the math
(Steps 1-6) before reaching for the arm.

**Step 7 is the robot-driving step.** With your derived angles
(`θ_1 = 90°, θ_2 = -45°, θ_3 = 0, θ_4 = 45°`), the course asks you
to verify that the physical tool orientation matches what you
computed and visualized in matplotlib.

Convert degrees to radians (`π/180 ≈ 0.01745`) and command:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 1.5708 -0.7854 0.0 0.7854"
```

(That's 90°, -45°, 0°, 45° in radians.)

When the arm pauses at the commanded angles (mid-sequence between
home and sleep), observe in rviz2 — the tool-frame orientation
should match your matplotlib plot and your hand-drawn diagram.
You may want to add a delay in the script (or temporarily change
`set_joint_positions` to be non-blocking with a longer dwell)
if you want more time to inspect.

To match the course's "selectively hide frames" instruction, see
Section F.4 of the pre-operation checklist — uncheck frames in the
TF display to focus on the tool frame alone.

---

## Lab 6 — Tool orientation using exponential coordinates

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-6:-Tool-Orientation-of-PincherX-100-Robot-Arm-Using-Exponential-Coordinates-and-Euler-Angles-Exercise-Question>

**No new robot motion.** The lab covers the same orientation
problem as Lab 5 but with exponential coordinates / Rodrigues'
formula in sympy, and a separate ZYX Euler-angle problem solved
with RoboDK. If a candidate solution emerges from the symbolic
math and lies within the px100's joint limits, you can verify it
on the arm by re-running `lab3_joint_control.py` with those
angles — same pattern as Lab 5 Step 7.

---

## Lab 7 — Pose in the zero position

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-7:-Pincherx-100-Robot-Arm's-Pose-in-Its-Zero-Position-and-Transformation-Matrices-for-Kinova's-Gen3-Robot-Arm>

**Part 1 Step 2** is the robot-driving step. The course asks you
to put the physical arm in its home (zero) pose and verify that
the M matrix you computed (from Trossen's technical drawing) lines
up with the measured EE position relative to the base.

You don't need a new script. Send the arm to home pose and observe:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0 0 0 0"
```

The script commands `[0, 0, 0, 0]` then returns through home to
sleep — too fast to measure with a ruler. Either:

- Take photos / measurements from the rviz2 frame display in the
  `dev` container window as the arm passes through home.
- Edit `lab3_joint_control.py` to skip the `set_joint_positions`
  + return-through-home segment and just call `go_to_home_pose()`,
  leaving the arm holding home while you measure.

For the course's "base frame + end-effector frame only" diagram /
screenshot view: use Section F.4 of the pre-operation checklist to
hide all TF frames except `world`, `px100/base_link`, and
`px100/ee_gripper_link` (and optionally hide the intermediate
RobotModel links to leave only the base and the end-effector
visible).

Either way, no new code. Part 2 of Lab 7 (Kinova Gen3) is paper
math; no arm.

---

## Lab 8 — Python library of math helpers

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-8:-Python-Code-for-All-the-Math-from-Lesson-3-up-to-Lesson-6>

**No robot motion.** Lab 8 is the development of a small library
of helper functions (skew-symmetric matrix builders, Rodrigues'
formula, SE(3) inverse, adjoint representation, screw-axis to
transformation matrix, etc.) that Lesson 7 onward — and the
follow-on projects — depend on. Worth doing once, off-arm, before
tackling Lab 9 and the projects. Save the helpers in
`~/px100-lab-scripts/lab8_helpers.py` (or wherever you prefer);
they don't need to go into the container until a script imports
them.

---

## Lab 9 — Forward kinematics using screw theory

Source: <https://github.com/madibabaiasl/modern-robotics-course/wiki/Lab-9:-PincherX-100-Robot-Arm's-Forward-Kinematics-Using-Screw-Theory>

**Part 1** is off-arm: port the MATLAB PoE forward-kinematics code
from Lesson 7 to Python. The Lab 8 helpers slot in here.

**Part 2** is the robot-driving step. Use your PoE Python code
(from Part 1) to compute the EE transformation matrix for the
course-prescribed angles (`θ_1 = 0, θ_2 = 0, θ_3 = -90°, θ_4 =
90°`), and then verify that the physical arm's EE pose matches
what you computed.

Convert and command:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0 0 -1.5708 1.5708"
```

The course then asks you to **choose another set of angles** (within
joint limits) and repeat. Pick something well inside the workspace,
e.g. `θ_1 = 30°, θ_2 = -30°, θ_3 = 30°, θ_4 = 0`:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && python3 /root/lab3_joint_control.py 0.5236 -0.5236 0.5236 0.0"
```

Same verification: compute the expected EE pose from your PoE code,
read the physical pose from the URDF in rviz2 (or measure with a
ruler), confirm they agree.

For the course's "hide the robot arm and all other frames but the
base frame and the end-effector frame" view (the canonical diagram
view in Lab 9): use Section F.4 to uncheck TF frames and (optionally)
RobotModel links. The course note about *"leave other links in case
you need to use one axis later for the rotation axis"* means: if
you're going to identify a screw axis as e.g. the shoulder's z-axis,
keep that frame visible too.

---

## Clean shutdown when you're done

In the first host terminal:

```
Ctrl-C
docker compose down
```

Unplug the arm PSU. Unplug the U2D2 if no further work this
session.

The image tag from Phase 5 (`px100-robot:dev`) remains the working
state; Phase 6 does not produce a new tag.

---

## Where to go next

The next two course exercises — **Project 1** and **Project 2 Part 1** —
are substantial in their own right and are not folded into this
walkthrough. Each is its own multi-hour exercise. They are
well-suited to the post-Phase-7 timeframe if the student wants
more px100 practice.

- **Project 1 — End-effector twist + dancing robot arm.**
  <https://github.com/madibabaiasl/modern-robotics-course/wiki/Project-1:-Computation-of-PincherX-100-End‐effector-Twist-Using-ROS-2-Utilities-and-The-Derived-Jacobian-‐-Did-someone-say-a-dancing-robot-arm?>
  Switches `modes.yaml` from `position` to `velocity` mode, creates
  a new colcon-managed ROS 2 package (`vel_tut`), runs a TF
  listener that derives the ground-truth EE twist, computes the
  same twist analytically via the body Jacobian, and publishes the
  error. The "wake → freeze → dance" pattern is open-ended — design
  your own moves.
  **For this Docker setup**: `modes.yaml` lives inside the patched
  Trossen workspace baked into `px100-robot:dev`. Changing it
  requires either (a) rebuilding the image with the new yaml
  (modify the Dockerfile or post-patch), or (b) overlaying a
  custom `modes.yaml` via a bind mount in `compose.yaml` for the
  duration of the project. A new colcon package (`vel_tut`) can
  similarly be a host-side workspace bind-mounted into `/root/`
  and built inside the container.

- **Project 2 Part 1 — Geometric and numerical inverse kinematics.**
  <https://github.com/madibabaiasl/modern-robotics-course/wiki/Project-2-‐-Part-1:-Inverse-Kinematics-of-the-PX100-robot-arm-Using-both-Geometric-and-Numerical-Approaches>
  Reverts `modes.yaml` to `position`, builds an `ourAPI` class with
  both geometric IK (closed-form, elbow-up solution) and Newton-
  Raphson numerical IK, and uses each in a grasp-then-release
  scenario. Foundation for the camera-aided IK in Part 2.

- **Project 2 Part 2 — vision-aided IK with AprilTag and RealSense.**
  Out of scope for this runbook. The Intel RealSense D415 USB 3.0
  pass-through is deferred per `CLAUDE.md`'s phase plan. Revisit
  when (or if) a perception phase is added.

After Phase 6, the runbook continues with
[Phase 7 — Flutter client over LAN](07-flutter-client-over-lan.md),
which builds the data path that lets a Flutter client on a phone
subscribe to `/px100/joint_states` (and other topics) via Zenoh.
After Phase 7 the Docker-Lyrical runbook is considered complete.

---

## Extras

### Shell function to cut the `docker exec` boilerplate

Each lab `docker exec` invocation repeats the same sourcing prefix.
Define this once per terminal session (or add to `~/.bashrc`):

```sh
rosexec() {
  docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && source /root/interbotix_ws/.venv/bin/activate && $*"
}
```

Then each lab run becomes:

```sh
rosexec python3 /root/lab3_joint_control.py 0.5 -0.5 0.5 0.0
```

The function is host-local — it's not part of the runbook
artifacts and not committed anywhere; it lives in your shell
session.

### Inspecting joint state from the host while a script runs

Open a third host terminal and tail topics through the same
exec wrapper:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && ros2 topic echo /px100/joint_states"
```

Or query the robot info service to see the arm's joint roster:

```sh
docker exec robot bash -c "source /opt/ros/lyrical/setup.bash && source /root/interbotix_ws/install/setup.bash && ros2 service call /px100/get_robot_info interbotix_xs_msgs/srv/RobotInfo \"{cmd_type: 'group', name: 'arm'}\""
```

Both queries reach the robot container via the federated Zenoh
router established in Phase 4.
