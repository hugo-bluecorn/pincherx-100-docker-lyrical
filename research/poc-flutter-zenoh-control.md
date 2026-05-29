# POC/MVP — Flutter + zenoh-dart direct control (home/sleep + per-joint jog)

Date: 2026-05-29

Part of the Python-free Flutter analysis chain (see
[`research/README.md`](README.md)). This is the first **concrete POC**:
a simple Flutter app on a mobile device that talks to the robot over
**`zenoh-dart`** — **no `rosbridge_suite`, no `foxglove_bridge`, no
gateway** — to:

1. **Two buttons** → command the arm to its **home** and **sleep** poses.
2. **Per-joint UI elements (sliders)** → move **one and only one joint at
   a time, within that joint's limits**.

Positional singularities are explicitly out of scope for now — and note
that for **direct joint control there is no IK and therefore no
singularity concern at all** (singularities are a Cartesian/IK problem;
see [`path-b-cartesian-gateway.md`](path-b-cartesian-gateway.md)).

## The big simplification

Both features are **direct joint-space commands** to fixed or
slider-chosen joint values. There is **no IK, no FK, no kinematics, and no
gateway needed for the math.** `go_to_home_pose` / `go_to_sleep_pose` in
`arm.py` just publish a fixed joint array; single-joint jogging publishes
one scalar. The POC reduces to *publishing two small message types to two
topics.*

The standard launch also puts the `arm` group in **position mode with a
time-based motion profile** (`modes.yaml`: `operating_mode: position`,
`profile_type: time`, `profile_velocity: 2000` ms, `profile_acceleration:
300` ms, `torque_enable: true`). So a bare command moves the arm
**smoothly over ~2 s with no service calls** — no need to set operating
modes or profile registers from the app.

## Messages, topics, values (verified from source)

| Feature | Message (`interbotix_xs_msgs/msg/…`) | Topic | Payload |
|---|---|---|---|
| Home button | `JointGroupCommand` (`string name`, `float32[] cmd`) | `/px100/commands/joint_group` | `{name:"arm", cmd:[0, 0, 0, 0]}` |
| Sleep button | `JointGroupCommand` | `/px100/commands/joint_group` | `{name:"arm", cmd:[0, -1.88, 1.5, 0.8]}` |
| Per-joint slider | `JointSingleCommand` (`string name`, `float32 cmd`) | `/px100/commands/joint_single` | `{name:<joint>, cmd:<radians>}` |

- The `arm` group = `[waist, shoulder, elbow, wrist_angle]` (config
  `px100.yaml`). Sleep `sleep_positions` are `[0, -1.88, 1.5, 0.8, 0]`
  (the trailing `0` is the gripper, untouched by the arm-group command).
- `JointSingleCommand` commands **exactly one joint** — so "one and only
  one joint at a time" is satisfied by the message itself. Moving one
  joint does not disturb the others (they hold their last commanded
  position under torque).

### Per-joint slider limits (radians) — from the px100 URDF

Authoritative limits from `interbotix_xsarm_descriptions/urdf/px100.urdf.xacro`
(`pi_offset = 0.00001`, negligible). Use these as the slider `min`/`max`;
`cmd` is the slider value in radians.

| Joint | Degrees | Radians (slider min … max) |
|---|---|---|
| `waist` | −180° … 180° | −3.14158 … 3.14158 |
| `shoulder` | −111° … 107° | −1.93732 … 1.86750 |
| `elbow` | −121° … 92° | −2.11185 … 1.60570 |
| `wrist_angle` | −100° … 123° | −1.74533 … 2.14675 |

Client-side slider bounds enforce the limits; the Dynamixel firmware
position limits (`Min/Max_Position_Limit` in `px100.yaml`) are an
independent backstop. For the POC, **hardcode** these (the alternative —
querying the `get_robot_info` service — is the impractical raw-Zenoh
service path; see "interface" below).

### Gripper is a special case (scope note)

The gripper (motor ID 5) launches in **PWM mode**, not position
(`modes.yaml singles.gripper.operating_mode: pwm`), so a `JointSingleCommand`
to it is interpreted as a **PWM effort**, not radians. The finger travel
is a prismatic 0.015–0.037 m. So the gripper does **not** fit the
radian-slider model. **v1 scope: the four position-mode arm joints.** If
gripper control is wanted, add a separate open/close pair of buttons
(PWM ±value) rather than a radian slider.

## The one hard requirement on the Zenoh wire (verified, `rmw_zenoh` `lyrical`)

This applies identically to **both** message types. A bare `z_put` of
key + CDR **silently fails**: the `rmw_zenoh_cpp` subscriber rejects any
sample without a Zenoh **attachment** (`rmw_subscription_data.cpp:221-237`
— missing attachment is logged as an error and the sample is dropped
before delivery). The attachment must be **ext-serialized** exactly as the
C++ publisher writes it (`attachment_helpers.cpp:67-82`): `int64
sequence_number`, `int64 source_timestamp`, `array<uint8,16> source_gid`.

`zenoh-dart` exposes every primitive needed — `Publisher.putBytes(payload,
attachment:)` and a `ZSerializer` with `serializeInt64` / `serializeUint8`
/ `serializeSequenceLength` / `finish` — so **the no-gateway direct path
is feasible** (verified at the API level; byte-level interop is the
empirical unknown to test on the arm).

## Interface decision for this POC

| | **Option 1 — direct to ROS topic (no robot-side code)** | **Option 2 — tiny C++ JSON gateway** |
|---|---|---|
| Robot-side work | none (existing `xs_sdk`) | build + deploy ~50-line gateway |
| Dart-side work | CDR (small msgs) + ext attachment + exact key | trivial — `z_put` JSON |
| What it proves | the riskiest path: raw `zenoh-dart` → ROS topic | only the gateway pattern |

**Recommendation: Option 1.** This POC is the ideal low-stakes place to
de-risk the core hypothesis of the whole Bluecorn architecture — *can
`zenoh-dart` command the arm over the ROS wire?* — because payloads are
tiny (4 floats / 1 float) with bounded values and zero kinematics. If it
works, the entire data path is validated. If attachment/QoS interop
proves fiddly, fall back to the ~50-line gateway (Option 2), which is the
[Path B](path-b-cartesian-gateway.md) direction anyway.

## The Dart recipe (Option 1)

1. **Connect** (client mode over WiFi to the robot-side router):
   `Config().insertJson5('connect/endpoints', '["tcp/<robot-host-LAN-ip>:7447"]')`
   → `Session.open`. Phase 4 already publishes `7447` on the host; the
   router must advertise a LAN-reachable locator (CLAUDE.md Phase 7).
2. **Keys** (hardcode the type hashes for the POC; capture once with
   `ros2 topic info -v <topic>`):
   - `0/px100/commands/joint_group/interbotix_xs_msgs::msg::dds_::JointGroupCommand_/RIHS01_<hash>`
   - `0/px100/commands/joint_single/interbotix_xs_msgs::msg::dds_::JointSingleCommand_/RIHS01_<hash>`
3. **CDR payload** (4-byte header `00 01 00 00` = LE XCDR1, then body):
   - `JointGroupCommand`: string `name` (`uint32` len incl. NUL + bytes +
     NUL) → pad to 4 → `cmd` (`uint32` count + N×`float32` LE).
   - `JointSingleCommand`: string `name` (as above) → pad to 4 → one
     `float32` LE.
4. **Attachment** via `ZSerializer`: `serializeInt64(seq++)`,
   `serializeInt64(nowNanos)`, `serializeSequenceLength(16)` +
   16×`serializeUint8(gid[i])`, `finish()`. Fixed random 16-byte GID +
   monotonic `seq`.
5. **Publish:** `publisher.putBytes(cdrBytes, attachment: attBytes)`. One
   publisher per key (two keys).

## Jogging UX and behavior (the time-profile interaction)

The launch profile is `profile_velocity = 2000` ms (each move takes ~2 s).
This is good for the pose buttons but shapes the slider design:

- **Send on release, not on every drag tick.** Use the Flutter `Slider`
  `onChangeEnd` callback to publish the final target once. Streaming
  intermediate values during a drag makes the arm chase stale targets
  (each queued for ~2 s) and lag badly.
- **Initialize / track sliders from actual joint state.** Subscribe to
  `/px100/joint_states` (`sensor_msgs/JointState`) so each slider starts
  at the joint's real current angle — otherwise the first touch can
  command a large jump. **Receiving is the easy path** — the attachment
  is ignored on the receive side (no CDR-attachment work needed to
  *read*), only CDR *decode* of the incoming message. This makes
  `joint_states` a recommended part of the jog feature, not just a
  stretch.
- **Responsive "live" jogging is a deliberate non-goal for v1.** It would
  require lowering `Profile_Velocity` via the `set_motor_registers`
  service — the impractical raw-Zenoh service path. Defer.
- Alternative to sliders: per-joint −/+ step buttons (fixed increment,
  clamped to limits). Same `JointSingleCommand`; simpler than tracking
  state, but coarser.

## Verification ladder (isolate failure points)

```
Step 0  From a normal ROS 2 terminal:
        ros2 topic pub --once /px100/commands/joint_single interbotix_xs_msgs/msg/JointSingleCommand "{name: elbow, cmd: 0.5}"
        ros2 topic pub --once /px100/commands/joint_group  interbotix_xs_msgs/msg/JointGroupCommand  "{name: arm, cmd: [0,-1.88,1.5,0.8]}"
        → confirms messages/values move the arm; capture both type hashes with `ros2 topic info -v`.
Step 1  Standalone Dart script: putBytes(key, CDR, attachment) for each.
        Verify with `ros2 topic echo` it's received → then the arm moves. Decouples wire from UI.
Step 2  Flutter app: 2 pose buttons + 4 jog sliders (+ joint_states subscribe to seed sliders).
```

Fast failure signal at Step 1: the `"Unable to obtain attachment for
topic"` error in the `xs_sdk`/router log = attachment missing or malformed.

## Residual risks to test on the arm

1. **Attachment ext-layout** — GID as length-prefixed (16) + 16×uint8
   (`zenoh-cpp serialization.hxx:236-240`); confirm against a captured
   real publication.
2. **QoS / AdvancedSubscriber matching** — `xs_sdk` commands use
   `declare_advanced_subscriber`; a plain Dart publisher should be
   received live, but verify.
3. **Endianness** — produce LE header; the rep-id byte tells FastCDR the
   body endianness.

## Safety and scope

- **Safety:** sleep folds the arm — clear the workspace; motion is gentle
  (2 s time profile); torque is already on from launch. Slider bounds +
  firmware limits prevent out-of-range commands.
- **In scope:** two pose buttons; four arm-joint jog sliders;
  `joint_states` subscribe to seed sliders.
- **Out of scope (and not needed):** IK/Cartesian, any ROS *service* call
  (launch handles modes/torque/profile), gripper radian control,
  live-streaming jog, singularities.

## Sources

Interbotix source (local clones, `lyrical` branch — provenance in
[`interbotix-python-cpp-boundary.md`](interbotix-python-cpp-boundary.md)):
- `interbotix_xs_msgs/msg/JointGroupCommand.msg`, `JointSingleCommand.msg` (message shapes)
- `interbotix_xsarm_control/config/modes.yaml` (operating mode + time profile)
- `interbotix_xsarm_control/config/px100.yaml` (group `arm`, `sleep_positions`, joint order, motor limits)
- `interbotix_xsarm_descriptions/urdf/px100.urdf.xacro:24-44, 104-282` (joint limits in radians)
- `interbotix_xs_modules/xs_robot/arm.py` (`go_to_home_pose`, `go_to_sleep_pose`, `set_single_joint_position`)

rmw_zenoh wire details (local `lyrical` clone; see
[`path-b-cartesian-gateway.md`](path-b-cartesian-gateway.md) for full cites):
- `rmw_zenoh_cpp/src/detail/rmw_subscription_data.cpp:221-237` (attachment required on take)
- `rmw_zenoh_cpp/src/detail/attachment_helpers.cpp:67-82` (ext-serialized seq/ts/gid)
- `rmw_zenoh_cpp/src/detail/liveliness_utils.cpp:87-93` (key-expression assembly)
- `rmw_zenoh_cpp/src/detail/type_support_common.cpp:42-46` (`dds_::Name_` mangling)
- `zenoh-cpp include/zenoh/api/ext/serialization.hxx:236-240` (array ext layout)

`zenoh-dart` (hugo-bluecorn/zenoh_dart, `main`):
- `package/lib/src/publisher.dart` (`putBytes(payload, attachment:)`), `package/lib/src/serializer.dart` (`ZSerializer`), `package/example/z_pub.dart`

Type-hash retrieval: `ros2 topic info -v` —
https://docs.ros.org/en/rolling/Tutorials/Beginner-CLI-Tools/Understanding-ROS2-Topics/Understanding-ROS2-Topics.html
