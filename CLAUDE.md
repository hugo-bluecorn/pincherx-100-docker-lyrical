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
- **Topology** — two-container, two-router, federated pattern on a
  user-defined Docker bridge network. Each container runs both
  `rmw_zenohd` (background, started by the image entrypoint) and a
  ROS 2 process group (foreground). The router and ROS 2 processes
  inside each container share the container's loopback, so
  rmw_zenoh's defaults (peer mode, `connect/endpoints:
  ["tcp/localhost:7447"]`, `listen/endpoints: ["tcp/localhost:0"]`)
  apply unchanged to the ROS 2 nodes. Federation between the two
  routers is one-directional via a `connect/endpoints` override on
  the dev-side router only; gossip propagates discovery in both
  directions across the link:
  ```
                  host LAN ─── port-publish 7447 ───┐
                                                    │
                                                    ▼
  ┌────────────────────────────────────────────────────────────┐
  │ px100-net (Docker user-defined bridge)                     │
  │                                                            │
  │ ┌──────────────────────────┐  ┌──────────────────────────┐ │
  │ │ robot container          │  │ dev container            │ │
  │ │ px100-robot:dev          │  │ px100-dev:dev            │ │
  │ │ (ros-base)               │  │ (desktop-full)           │ │
  │ │ rmw_zenohd (bg)          │◄►│ rmw_zenohd (bg)          │ │
  │ │   default router config  │  │   override applied via   │ │
  │ │                          │  │   ZENOH_CONFIG_OVERRIDE  │ │
  │ │ xs_sdk (fg, peer,        │  │ rviz2 (fg, peer,         │ │
  │ │   default session)       │  │   default session)       │ │
  │ │ --device=/dev/ttyDXL     │  │ --device=/dev/dri/...    │ │
  │ │                          │  │ + /tmp/.X11-unix mount   │ │
  │ └──────────────────────────┘  └──────────────────────────┘ │
  └────────────────────────────────────────────────────────────┘
  ```
  This pattern was adopted in Phase 4 (see
  `runbook/04-topology-proof-urdf-tutorial.md`) after primary-source
  research showed it is the rmw_zenoh-canonical layout for
  multi-fault-domain deployment. It supersedes the earlier
  single-shared-router + client-mode pattern from Phase 3.
- **Middleware**: `rmw_zenoh_cpp` from inception. No DDS, no
  `zenoh-bridge-ros2dds`. Installed via apt as
  `ros-lyrical-rmw-zenoh-cpp`. In the OSRF Lyrical Docker image the
  package resolves from `packages.ros.org/ros2-testing/ubuntu resolute`
  (the testing repo is configured by OSRF in addition to Ubuntu's own
  archive). Production deployments should evaluate pinning to the stable
  ROS apt repo when one is published for Lyrical.
- **Image base**: two role-specific images built from a single
  parameterized `docker/Dockerfile`. The `BASE_IMAGE` arg selects the
  upstream tier; `EXTRA_PKGS` adds per-role apt packages:
  - **Robot** (`px100-robot:dev`): `ros:lyrical-ros-base-resolute`
    from the official Docker Hub `library/ros` namespace (~324 MB,
    headless — includes tf2, robot_state_publisher, urdf, xacro,
    colcon, rosdep; no rviz, no Qt, no X11 deps).
  - **Dev** (`px100-dev:dev`): `osrf/ros:lyrical-desktop-full-resolute`
    from the OSRF Docker Hub namespace (~1.77 GB — adds rviz2, rqt,
    the full ROS desktop tooling).
  The upstream ROS Docker images are published under two namespaces:
  `library/ros` (Docker Official Images — lean tiers: ros-core,
  ros-base, perception) and `osrf/ros` (OSRF profile — GUI-heavy
  tiers: desktop, desktop-full, simulation). See
  https://hub.docker.com/_/ros and https://hub.docker.com/r/osrf/ros.
  Both images share a common custom layer that installs
  `ros-lyrical-rmw-zenoh-cpp`, sets
  `ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp`, and installs a custom
  entrypoint (`docker/entrypoint.sh`) that starts `rmw_zenohd` in
  the background before the main command. `docker compose build`
  builds both images. See `docker/Dockerfile` and `compose.yaml`.
- **Zenoh session mode**: **peer mode for all ROS 2 nodes** — this
  is rmw_zenoh's default and matches the ROS-canonical "router per
  fault domain, peers connect via gossip" pattern documented in
  `rmw_zenoh/README.md`. The router and its colocated peers share
  the container's loopback, so rmw_zenoh's default
  `connect/endpoints: ["tcp/localhost:7447"]` and
  `listen/endpoints: ["tcp/localhost:0"]` work as designed. No
  session overrides are needed on any ROS 2 node container.
  Cross-container communication happens via router-to-router
  federation (see next bullet).
- **`ZENOH_CONFIG_OVERRIDE` syntax** (per
  https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md): semicolon-
  separated `key/path=value` pairs. Example used for the dev-side
  router federation: `connect/endpoints=["tcp/robot:7447"]`.
  Overrides apply to whichever Zenoh config file the process is
  loading (session for ROS nodes, router for `rmw_zenohd`). **The
  image entrypoint scopes the override to the router only** by
  unsetting `ZENOH_CONFIG_OVERRIDE` after `rmw_zenohd` starts but
  before the main command runs; otherwise the same override would
  apply to ROS 2 nodes' session configs too, defeating the topology.
  This scoping is the cleanest alternative to shipping a full copy
  of the 230-line default router config file per container.
- **Robot**: Trossen Interbotix PincherX-100, single arm.
- **Robot interface**: U2D2 USB-serial adapter (FTDI FT232H, vendor
  0x0403, product 0x6014). Host gets the Trossen udev rule so
  `/dev/ttyDXL` enumerates correctly on plug-in. Container receives the
  device via `--device=/dev/ttyDXL:/dev/ttyDXL`. udev runs on the host
  only; the container does not (and cannot) process udev events.
- **Camera**: Intel RealSense D415 via USB 3.0. Deferred until arm
  control is verified end-to-end.
- **Graphics**: containerized rviz via **XWayland**, not native Wayland.
  Ubuntu 26.04 Resolute runs Wayland-only compositors (GNOME 50 dropped
  its X11 backend entirely; KDE Plasma defaults to Wayland), but XWayland
  (`xwayland` package, `main` section) is installed by default and
  auto-started by the compositor. rviz2 **cannot run on native Wayland**
  due to three independent X11 hard dependencies:
  (1) `rviz2/src/main.cpp` detects Wayland and forces `-platform xcb`
  (https://github.com/ros2/rviz/pull/1253, present on `lyrical` branch);
  (2) `rviz_rendering/render_system.cpp` directly calls X11/GLX APIs
  (`XOpenDisplay`, `glXChooseVisual`, `glXCreateContext`);
  (3) the vendored OGRE 1.12.10 (`rviz_ogre_vendor`) has no Wayland
  support — Wayland was added in OGRE 14.3.0+ behind
  `-DOGRE_USE_WAYLAND=TRUE`, but rviz has not adopted it (tracked in
  https://github.com/ros2/rviz/issues/847).
  Containers bind-mount `/tmp/.X11-unix` (the XWayland socket) and
  `/dev/dri/renderD128` (Intel Iris Xe iGPU on this Dell Precision 3581).
  `QT_QPA_PLATFORM=xcb` is set in compose for explicitness, though
  rviz2 forces it automatically. `xhost +local:docker` grants container
  access to the XWayland server; re-run after each reboot.
  `joint_state_publisher_gui` (pure Qt, no OGRE) could run on native
  Wayland, but shares the xcb setting with rviz2 for simplicity.
  Mesa userspace in the image. No NVIDIA Container Toolkit needed.
- **Network**: user-defined Docker bridge for inter-container Zenoh.
  Default Zenoh ports: TCP 7447 (router), UDP 7446 (multicast scout,
  disabled by default). Multicast disabled in both router and session
  configs — Zenoh discovery is TCP-unicast via the router, which
  sidesteps the Docker-multicast-across-netns problem DDS has. No
  `--network=host` required.
- **External middleware**: Flutter client (Bluecorn) consumes Zenoh
  keyexpressions via `package:zenoh` — a Dart FFI binding over
  zenoh-c, maintained at https://github.com/hugo-bluecorn/zenoh_dart
  (not under the `eclipse-zenoh` org; community binding by this
  project's author). The pattern is proven end-to-end in the
  `zenoh-counter-flutter` template at
  https://github.com/hugo-bluecorn/zenoh-counter-flutter, where the
  Flutter app runs in client mode (`mode="client"`) and connects via
  TCP over WiFi to the host's published router endpoint
  (`tcp/<host-LAN-ip>:7447`). The phone-as-client + router-on-robot
  shape is exactly what `rmw_zenoh/README.md` § "Connecting to the
  Zenoh router on another host" prescribes for remote nodes. Phase 8
  wires this in for the PincherX-100; the bridge layer
  (`zenoh-bridge-ros2dds`) is not required because both ends speak
  Zenoh natively.
- **Install method**: patched Trossen `xsarm_amd64_install.sh`
  forked into `installers/`. Patch surface inherited from the
  Lyrical-Luth fork's Phase-3a plan plus containerization-specific
  adaptations: strip `sudo`, no-op the `udevadm trigger` (host-side
  only), and replace `pip install` user-site installs with a
  venv-based pattern for PEP 668 compliance.

## Implementation phases (in order)

1. **Host preparation** — install Docker engine + BuildKit + Compose v2
   on Ubuntu 26.04 Resolute via apt (`docker.io`, `docker-buildx`,
   `docker-compose-v2`). Add user to the `docker` group with new
   membership effective. Verify `docker run hello-world` works without
   `sudo`. Verify `docker buildx version` and `docker compose version`
   resolve. The Trossen udev rule install and `/dev/ttyDXL` verification
   move to Phase 5, where the U2D2 is actually plugged in. Runbook:
   `runbook/01-host-preparation.md`.
2. **Image build** — single parameterized Dockerfile with `BASE_IMAGE`
   and `EXTRA_PKGS` build args. Robot image extends
   `ros:lyrical-ros-base-resolute` (official `library/ros`); dev
   image extends `osrf/ros:lyrical-desktop-full-resolute` (OSRF
   namespace). Both install `ros-lyrical-rmw-zenoh-cpp` and the
   custom entrypoint at `/px100-entrypoint.sh`. Per-role packages
   (e.g. `ros-lyrical-urdf-tutorial` for Phase 4) passed via
   `EXTRA_PKGS`. Patched Trossen installer fork + colcon workspace
   build deferred to Phase 5. Build both via `docker compose build`
   or individually via `docker buildx build --load` with explicit
   `--build-arg`.
3. **Network + router (Phase 3 prototype, SUPERSEDED by Phase 4)** —
   single-shared-router + client-mode topology validated cross-container
   message flow as a first proof-of-life. This shape is retained as
   historical record in `runbook/03-network-router.md` but is replaced
   in Phase 4 by the rmw_zenoh-canonical pattern. Do not adopt the
   Phase 3 compose.yaml for new work.
4. **Topology proof with urdf_tutorial** — replace the single-router
   topology with the two-container, two-router, federated pattern
   that the rest of the project depends on. Robot container runs
   `rmw_zenohd` + `robot_state_publisher` against the
   `urdf_tutorial`-shipped `06-flexible.urdf`. Dev container runs
   `rmw_zenohd` (federated to robot via
   `ZENOH_CONFIG_OVERRIDE='connect/endpoints=["tcp/robot:7447"]'`,
   applied via the entrypoint and scoped to the router only) +
   `joint_state_publisher_gui` + `rviz2`. Verify bidirectional topic
   flow: `/joint_states` (dev → robot), `/tf` +
   `/robot_description` (robot → dev). Visually: rviz2 renders the
   URDF and reflects slider-driven joint state changes in real time.
   Robot-side router publishes port 7447 on the host LAN for the
   future Phase 8 Flutter client. Runbook:
   `runbook/04-topology-proof-urdf-tutorial.md`.
5. **Controller container + USB pass-through + arm verification** —
   swap the `urdf_tutorial` publisher in the robot container for
   `xs_sdk` / the patched Trossen workspace. Install Trossen's
   `99-interbotix-udev.rules` at `/etc/udev/rules.d/` on the host
   (relocated here from Phase 1 because it requires the U2D2 to be
   plugged in for verification). Reload udev rules
   (`sudo udevadm control --reload-rules && sudo udevadm trigger`),
   plug in the U2D2, confirm `/dev/ttyDXL` symlink appears on the host.
   Then add `--device=/dev/ttyDXL:/dev/ttyDXL` to the robot service
   in `compose.yaml`. Confirm `/dev/ttyDXL` appears inside the
   container. Power on the arm. `docker compose up robot` launches
   `xsarm_control.launch.py` for the px100. Confirm `/px100/joint_states`
   publishes at ~100 Hz, all 5 Dynamixels are detected, and a
   sleep → home → sleep round-trip via a connect-check script exits
   cleanly. The topology, federation, and rviz subscriber are
   unchanged from Phase 4 — only the publisher changes. Tag images.
6. **Pedagogical motion exercise** — walk a student sequentially through
   the robot-driving exercises in Labs 3-9 of Babaiasl's *Modern
   Robotics* course wiki (Saint Louis University): joint position
   control, Cartesian-space pick-and-place, DOF demonstration,
   rotation-matrix and PoE forward-kinematics verification against
   the physical arm. Pedagogical, not a verification gate — Phase 5
   already establishes that the motion plumbing works. Phase 6
   produces a single walkthrough document; per-lab scripts live in
   `~/px100-lab-scripts/` on the host and are copied into the robot
   container via `docker cp` per run. **License caveat**: the
   Babaiasl course is licensed for non-commercial use only
   (`NOASSERTION`); the walkthrough adapts the high-level
   `InterbotixManipulatorXS` API-usage pattern (itself documented
   Trossen public API), not the course's authored prose, math, or
   fill-in-the-blank skeletons. Project 1 (velocity-mode Jacobian
   dance) and Project 2 Part 1 (geometric + numerical IK) are listed
   as post-runbook next steps in the walkthrough; Project 2 Part 2
   (vision-aided IK) is out of scope until a RealSense pass-through
   phase is added.
7. **(Optional) Flutter client over LAN** — Flutter app on a mobile
   device (Pixel 9a or similar) subscribes to `/px100/joint_states`
   via `package:zenoh` in client mode, connecting over WiFi to
   `tcp/<host-LAN-ip>:7447`. The robot-side router port is already
   published in Phase 4's compose; what's new in this phase is the
   router-side override to advertise a LAN-reachable locator (rather
   than the bridge IP) via gossip. Pattern is proven in the
   `zenoh-counter-flutter` template repo's Android branch. Goal:
   prove the data path end-to-end; not full Bluecorn integration.
   After Phase 7 the Docker-Lyrical runbook is considered complete.

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
- **The Flutter client binding is `package:zenoh`** from
  https://github.com/hugo-bluecorn/zenoh_dart (community Dart FFI
  binding over zenoh-c, maintained by this project's author). Not
  in the `eclipse-zenoh` org. Proven in production by the
  `zenoh-counter-flutter` template at
  https://github.com/hugo-bluecorn/zenoh-counter-flutter.
- **rviz2 requires XWayland, not native Wayland.** Three independent
  blockers (main.cpp xcb override, rviz_rendering GLX calls, OGRE
  1.12.10 lacking Wayland support) prevent native Wayland rendering.
  On Resolute, XWayland is in `main`, installed by default, and
  auto-started by the compositor. Containers bind-mount
  `/tmp/.X11-unix` and use `DISPLAY=$DISPLAY` + `QT_QPA_PLATFORM=xcb`
  to reach the XWayland server. `xhost +local:docker` on the host
  grants access. No standalone Xorg session is needed or available.
- **Multicast Zenoh discovery is disabled by default** in
  `rmw_zenoh_cpp`. Containers need explicit
  `connect.endpoints` overrides — no "it just works on the same
  Docker bridge" without configuration.
- **rmw_zenoh defaults assume one router + its peers share one
  network namespace.** Default session config has
  `listen/endpoints: ["tcp/localhost:0"]` and
  `connect/endpoints: ["tcp/localhost:7447"]` — both loopback. This
  is deliberate (per `rmw_zenoh/README.md` § "Configuration") and
  makes peer-to-peer work over loopback after gossip-based discovery
  through the local router. **Cross-netns ROS 2 setups (Docker
  containers in separate netns, multiple hosts) need one router per
  netns** plus federation between routers — NOT a single shared
  router with peers across netns. The Phase 3 prototype's empirical
  failure (peers in separate containers couldn't reach each other's
  advertised loopback addresses) was diagnosed as this constraint;
  Phase 4 adopts the rmw_zenoh-canonical fix (router per container
  + federation override on one router) and the project's topology
  follows that pattern from then on.

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
