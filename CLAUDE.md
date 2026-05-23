# PincherX-100 ROS 2 Lyrical Luth Docker Setup

## Project goal

Stand up a development environment to operate a single Trossen Interbotix
PincherX-100 robotic arm using ROS 2 Lyrical Luth, with every ROS component
running inside Docker containers on a bare-metal Ubuntu 26.04 Resolute host.
The setup must support a downstream Flutter client (Bluecorn) consuming the
arm's ROS topics over Zenoh-native middleware, with no DDS layer.

This project is a sibling fork of the upstream Humble runbook
(https://github.com/hugo-bluecorn/pincherx-100-runbook) and the
QEMU/KVM-based Lyrical attempt
(https://github.com/hugo-bluecorn/pincherx-100-runbook-lyrical-luth).
Both predecessors remain on GitHub as historical records. This repo
pursues containerization instead of VM-based isolation; see
`research/docker-architecture.md` for the primary-source research
that justifies each architectural decision below.

The PincherX-100 has been **discontinued** by Trossen
(https://www.trossenrobotics.com/pincherx100 — "THIS PRODUCT HAS BEEN
DISCONTINUED"). Trossen's `xsarm_amd64_install.sh` stopped officially
validating distros past Humble. **This project is community-maintained
from Lyrical onward.**

## Architecture (decided)

- **Host**: Ubuntu 26.04 Resolute (bare metal). REP-2000 Tier-1 platform
  for ROS 2 Lyrical Luth. No VM layer, no virtio-gpu, no nested KVM. The
  host runs Docker engine, Trossen's udev rules, and (optionally) OSRF's
  `rocker` for dev-loop ergonomics.
- **Container runtime**: Docker engine (apt: `docker.io` on Resolute, or
  the upstream `docker-ce` repo per https://docs.docker.com/engine/install/ubuntu/).
- **Topology** — three-container minimum on a user-defined Docker bridge
  network:
  ```
  ┌─────────────────────────┐
  │ rmw_zenohd router       │  tcp 7447
  │  (no client override)   │
  └────────────┬────────────┘
               │ Zenoh TCP unicast, mode=client
     ┌─────────┴──────────┐
     ▼                    ▼
  controller container   rviz container
  xs_sdk + rmw_zenoh     rviz2 + rmw_zenoh
  --device=/dev/ttyDXL   --device=/dev/dri/renderD128
                         + /tmp/.X11-unix bind-mount
  ```
- **Middleware**: `rmw_zenoh_cpp` from inception. No DDS, no
  `zenoh-bridge-ros2dds`. Installed via apt as
  `ros-lyrical-rmw-zenoh-cpp`. In the OSRF Lyrical Docker image the
  package resolves from `packages.ros.org/ros2-testing/ubuntu resolute`
  (the testing repo is configured by OSRF in addition to Ubuntu's own
  archive). Production deployments should evaluate pinning to the stable
  ROS apt repo when one is published for Lyrical.
- **Image base**: single `osrf/ros:lyrical-desktop-full-resolute` for
  all three containers. The `desktop-full` variant ships rviz + the
  full ROS desktop tooling; one image keeps build and operations simple
  at the cost of ~2 GB per image (most layers shared with the OSRF
  base). Custom layer adds `ros-lyrical-rmw-zenoh-cpp` and sets
  `ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp`. See `docker/Dockerfile`.
- **Zenoh session mode**: non-router containers run with
  `mode="client"` (override of rmw_zenoh's default `mode="peer"`).
  Peer mode advertises a loopback listen-locator that other containers
  can't reach across Docker bridges; client mode relays all
  communication through the router. The router itself runs with its
  default config (router mode); only the talker / listener / rviz /
  controller containers carry the override. Asymmetry is documented
  here so the runbook's launch commands set the env var only where
  appropriate.
- **`ZENOH_CONFIG_OVERRIDE` syntax** (per
  https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md): semicolon-
  separated `key/path=value` pairs. Example:
  `mode="client";connect/endpoints=["tcp/router:7447"]`. Overrides
  apply to whichever Zenoh config file the process is loading
  (session for ROS nodes, router for `rmw_zenohd`).
- **Robot**: Trossen Interbotix PincherX-100, single arm.
- **Robot interface**: U2D2 USB-serial adapter (FTDI FT232H, vendor
  0x0403, product 0x6014). Host gets the Trossen udev rule so
  `/dev/ttyDXL` enumerates correctly on plug-in. Container receives the
  device via `--device=/dev/ttyDXL:/dev/ttyDXL`. udev runs on the host
  only; the container does not (and cannot) process udev events.
- **Camera**: Intel RealSense D415 via USB 3.0. Deferred until arm
  control is verified end-to-end.
- **Graphics**: containerized rviz with X11 socket bind-mount and
  `/dev/dri/renderD128` (Intel Iris Xe iGPU on this Dell Precision 3581).
  Mesa userspace in the image. No NVIDIA Container Toolkit needed for
  the default architecture. Ubuntu 26.04 GNOME defaults to Wayland;
  rviz2 forces `QT_QPA_PLATFORM=xcb` so XWayland handles the bridge
  (https://github.com/ros2/rviz/pull/1253).
- **Network**: user-defined Docker bridge for inter-container Zenoh.
  Default Zenoh ports: TCP 7447 (router), UDP 7446 (multicast scout,
  disabled by default). Multicast disabled in both router and session
  configs — Zenoh discovery is TCP-unicast via the router, which
  sidesteps the Docker-multicast-across-netns problem DDS has. No
  `--network=host` required.
- **External middleware**: Flutter client (Bluecorn) consumes Zenoh
  keyexpressions. `zenoh-dart` does **not** exist in the
  `eclipse-zenoh` GitHub org; the Flutter client path uses
  `zenoh-pico` via Dart FFI, a community Dart binding (if vetted), or
  a REST/WebSocket bridge. Decision deferred to the
  Phase-7-equivalent design step.
- **Install method**: patched Trossen `xsarm_amd64_install.sh`
  forked into `installers/`. Patch surface inherited from the
  Lyrical-Luth fork's Phase-3a plan plus containerization-specific
  adaptations: strip `sudo`, no-op the `udevadm trigger` (host-side
  only), and replace `pip install` user-site installs with a
  venv-based pattern for PEP 668 compliance.

## Implementation phases (in order)

1. **Host preparation** — install Docker engine on Ubuntu 26.04 Resolute.
   Add user to the `docker` group. Install Trossen's udev rule at
   `/etc/udev/rules.d/99-interbotix-udev.rules`. Verify `/dev/ttyDXL`
   appears on U2D2 plug-in. Verify `docker run hello-world`.
2. **Image build** — single Dockerfile extending
   `osrf/ros:lyrical-desktop-full-resolute`. Install
   `ros-lyrical-rmw-zenoh-cpp`. Add the patched Trossen installer fork
   as a build step. Build the Trossen colcon workspace inside the
   image. Tag image at phase exit as `px100-base:phase2`. Build via
   BuildKit (`docker buildx build --load`); legacy `docker build`
   is deprecated upstream. A prototype scaffold of the Dockerfile
   landed in Phase 0 at `docker/Dockerfile` (rmw_zenoh layer only;
   Trossen workspace deferred to this phase).
3. **Network + router** — create a user-defined Docker bridge network
   (`docker network create pincherx100-net`). Launch a `rmw_zenohd`
   router container on the network. Verify nodes in subsequent
   containers can connect by overriding session `connect.endpoints`
   to `tcp/<router-container-name>:7447`.
4. **Controller container + USB pass-through** — launch the
   controller container with `--device=/dev/ttyDXL:/dev/ttyDXL`,
   `--network=pincherx100-net`, `RMW_IMPLEMENTATION=rmw_zenoh_cpp`,
   `ZENOH_CONFIG_OVERRIDE='connect/endpoints=["tcp/router:7447"]'`.
   Confirm `/dev/ttyDXL` appears inside the container (smoke-test the
   `--device=src:dst` symlink behavior; if it doesn't preserve the
   symlink name, fall back to entrypoint `ln -sf` or patch
   `xs_sdk_obj.h:22` to accept a port parameter).
5. **Connection verification** — power on the arm. Launch
   `interbotix_xsarm_control` for the px100 model inside the
   controller container. Confirm `/px100/joint_states` publishes at
   100 Hz (read from outside the container via a transient
   `ros2 topic echo` container on the same network). Verify the arm
   responds to a single command to go to its starting (sleep) pose.
   Tag images.
6. **rviz container + display verification** — launch the rviz
   container with `--device=/dev/dri/renderD128`, X11/Wayland socket
   bind-mounts, `--user $(id -u):$(id -g)`, and the same
   `RMW_IMPLEMENTATION` / Zenoh endpoint override as the controller.
   Verify rviz2 renders the URDF and reflects live joint states.
7. **Pedagogical motion exercise** — adapt Lab 3 Code Example 2 from
   the Babaiasl *Modern Robotics* course (Saint Louis University) —
   `set_single_joint_position`, `set_ee_cartesian_trajectory`,
   `gripper.set_pressure` in a mock pick-and-place sequence. Confirms
   the arm executes a multi-step Cartesian-space sequence and that
   the containerized rviz holds up under live motion. **License
   caveat**: the Babaiasl course is licensed for non-commercial use
   only (`NOASSERTION`); patterns may be referenced but no code is
   bundled into shipped product.
8. **(Optional) Hello-world Flutter client** — implement a minimal
   Flutter app that subscribes to `/px100/joint_states` via Zenoh.
   Requires deciding the binding path first (`zenoh-pico` + Dart
   FFI, community Dart binding, or REST/WebSocket bridge). Goal:
   prove the data path end-to-end; not full Bluecorn integration.
   After Phase 8 the Docker-Lyrical runbook is considered complete.

## Out of scope

- ROS distributions other than Lyrical Luth (Humble is covered by the
  parent runbook; future distros are a separate exercise)
- VM-based isolation (QEMU/KVM is the parent project's path; this
  fork exists specifically to avoid it)
- Kubernetes or multi-host orchestration; single-host Docker only
- Docker Swarm
- VFIO / GPU passthrough (different paradigm; iGPU access via
  `/dev/dri/renderD128` is sufficient)
- Multi-arm or ALOHA-style configurations
- PREEMPT_RT / Ubuntu Pro real-time kernel
- Gazebo simulation parity
- Perception (D415 camera) integration before arm control verified
- Trossen's perception_pipeline (deferred per parent runbook)

## Key constraints

- **PincherX-100 is discontinued upstream.** No upstream maintenance
  past Humble. This is a community fork. Hardware-side issues (motor
  calibration, U2D2 firmware) escalate to ROBOTIS, not Trossen.
- **Neither Trossen nor Docker officially support each other.** This
  pivot proceeds knowing that. Workarounds for Trossen-installer
  assumptions are documented in the patched `installers/` fork.
- **`--device` assignments are static at container create-time.** USB
  hot-plug requires `--device-cgroup-rule` major:minor whitelisting,
  or container restart on replug. Worse than libvirt's
  `<hostdev managed='yes'>` reattach behavior.
- **Container `--device` resolves symlinks to targets** (Docker 1.11.0+).
  `/dev/ttyDXL` arrives inside the container as `/dev/ttyUSB0`. The
  `xs_sdk` has the symlink path hardcoded; handle in entrypoint or
  via `--device=src:dst`.
- **udev runs only on the host.** Trossen's
  `99-interbotix-udev.rules` must be installed in
  `/etc/udev/rules.d/` on the host. The container does not (and
  cannot) process udev events.
- **`zenoh-dart` does not exist.** The Flutter client path is a
  research-required follow-up, not a turnkey integration.
- **rviz2 on Wayland needs XWayland** even in 2026; bind-mount
  `/tmp/.X11-unix` regardless of host session type.
- **Multicast Zenoh discovery is disabled by default** in
  `rmw_zenoh_cpp`. Containers need explicit
  `connect.endpoints` overrides — no "it just works on the same
  Docker bridge" without configuration.
- **rmw_zenoh's default session mode is `peer`**, which advertises a
  loopback-only listen-locator. Cross-container peer-to-peer fails
  silently — the listener can discover the talker (via the router's
  gossip) but can't connect to its loopback address. Verified
  empirically 2026-05-23; see `research/docker-architecture.md`
  "Empirical verification" section. Fix: every non-router container
  sets `mode="client"` via `ZENOH_CONFIG_OVERRIDE`. The router
  container must NOT receive this env var.

## Working conventions

- **RTFM before instructing.** Fetch and read actual documentation,
  READMEs, or source before recommending commands. Do not guess
  from shallow web search snippets.
- **Primary upstream sources only.** Citations in project artifacts
  must come from canonical project pages (docs.docker.com,
  docs.ros.org, packages.ros.org, Eclipse Zenoh repos,
  kernel.org). Third-party blogs are not citations.
- **Lead with the primary action.** Optional alternatives, tangents,
  and edge cases go under an "Extras" subheading or equivalent.
- **Defaults unless deviation is necessary.** Use the tool's default
  port/path/name unless there's a concrete reason to override.
- **Dockerfiles and Compose files are canonical.** Image definitions
  live in version control; the patched installer fork lives in
  `installers/`. Reproduce on any host via `docker compose build`.
- **Image tags at phase boundaries** replace qcow2 disk snapshots
  from the parent runbook. Tag after each phase's hardware
  verification: `pincherx100-controller:phaseN`, etc.
- **Per-phase commits only after hardware verification.** Same
  cadence as the parent runbook.
- **Inventory before install.** Same pattern as the parent runbook:
  capture `docker info`, `apt list --installed`, group membership
  before running install commands.

## References

- Trossen X-series docs (ROS 2, preserved post-discontinuation):
  https://docs.trossenrobotics.com/interbotix_xsarms_docs/
- Trossen install script (we patch this):
  https://raw.githubusercontent.com/Interbotix/interbotix_ros_manipulators/main/interbotix_ros_xsarms/install/amd64/xsarm_amd64_install.sh
- PincherX-100 discontinuation banner:
  https://www.trossenrobotics.com/pincherx100
- ROS 2 Lyrical Luth installation:
  https://docs.ros.org/en/lyrical/Installation.html
- ROS 2 platform support (REP-2000):
  https://www.ros.org/reps/rep-2000.html
- OSRF Docker images (canonical Dockerfiles):
  https://github.com/osrf/docker_images
- OSRF rocker (Docker wrapper for ROS dev loops):
  https://github.com/osrf/rocker
- rmw_zenoh (Lyrical branch):
  https://github.com/ros2/rmw_zenoh/tree/lyrical
- Eclipse Zenoh:
  https://github.com/eclipse-zenoh/zenoh
- Docker engine reference:
  https://docs.docker.com/reference/cli/docker/container/run/
- Docker on Ubuntu install guide:
  https://docs.docker.com/engine/install/ubuntu/
- Linux cgroup v2 admin guide (device controller via eBPF):
  https://docs.kernel.org/admin-guide/cgroup-v2.html
- Mesa env vars (DRI_PRIME for hybrid graphics):
  https://docs.mesa3d.org/envvars.html
- Architectural research synthesis for this project:
  `research/docker-architecture.md` (in this repo)
