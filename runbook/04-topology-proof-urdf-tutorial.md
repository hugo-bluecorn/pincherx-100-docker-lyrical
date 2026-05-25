# 04 — Topology proof with urdf_tutorial

Prove that the corrected two-container, two-router, federated Zenoh
topology actually works end-to-end before any robot hardware (xs_sdk,
U2D2, PincherX-100 arm) enters the picture. The publisher in this
phase is the standard ROS 2 `urdf_tutorial` package — a known-good
stand-in for what `xs_sdk` will be in a later phase. The subscriber
is `rviz2` rendering the URDF, with `joint_state_publisher_gui`
driving joint values via slider input.

This phase **supersedes** Phase 3's client-mode topology. Phase 3
verified that the project's middleware stack works in the simplest
single-router-with-clients shape. This phase replaces that shape
with the rmw_zenoh-canonical pattern: one router per fault domain,
ROS 2 nodes as peers using rmw_zenoh's default config, federation
via a router config-side override. See "Why the pattern changed"
below for the rationale.

## Goal

After this phase:

- A two-container topology on `px100-net` (Docker bridge): one
  `robot` container, one `dev` container.
- Each container runs `rmw_zenohd` as a background process (started
  by the image's entrypoint) AND a foreground ROS 2 process group.
- The two routers are federated by a one-direction `connect/endpoints`
  override applied to the `dev` container's router only.
- The `robot` container's `robot_state_publisher` consumes
  `/joint_states` from the network and publishes `/tf` +
  `/robot_description`.
- The `dev` container's `joint_state_publisher_gui` publishes
  `/joint_states`; `rviz2` subscribes and renders the URDF, updating
  the model live as sliders move.
- The robot-side router publishes port `7447` on the host LAN
  interface in preparation for the future Flutter-from-phone case
  (Phase 8+); the dev-side router stays internal.

## Scope explicitly excluded

- `xs_sdk` / Trossen workspace / patched installer — deferred to
  Phase 5 ("controller container + USB pass-through"), which will
  swap the `urdf_tutorial` publisher for the real arm.
- U2D2 USB pass-through — Phase 5.
- Flutter client connecting to robot-router over WiFi — Phase 8.
- `interbotix_xsarm_descriptions` URDF — could be a Phase 4a slice
  after this one (uses real px100 URDF without xs_sdk), or rolled
  into Phase 5.

## Prerequisites

- Phases 1 and 2 complete.
- Phase 2's `px100-base:dev` image may be present (verify with
  `docker images px100-base`); this phase replaces it with two
  role-specific images (`px100-robot:dev` and `px100-dev:dev`).
- XWayland running on the host. Ubuntu 26.04 Resolute installs
  `xwayland` by default (`main` section) and the Wayland compositor
  auto-starts it. Verify with `echo $DISPLAY` (should be `:0` or
  `:1`) and `ls /tmp/.X11-unix/` (socket file should exist). See
  Step 5 for troubleshooting if XWayland hasn't started yet.
- `xhost` available on the host (`x11-xserver-utils` package,
  installed by default on Resolute; `apt install x11-xserver-utils`
  if not).

## Sources

Primary upstream only. Do not extrapolate from convention; cross-check
each before recommending.

- rmw_zenoh README (Lyrical branch), § "Connecting multiple hosts":
  https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md#connecting-multiple-hosts
- rmw_zenoh default router config:
  https://github.com/ros2/rmw_zenoh/blob/lyrical/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5
- rmw_zenoh default session config:
  https://github.com/ros2/rmw_zenoh/blob/lyrical/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5
- Eclipse Zenoh default config:
  https://github.com/eclipse-zenoh/zenoh/blob/main/DEFAULT_CONFIG.json5
- urdf_tutorial package (ROS 2):
  https://github.com/ros/urdf_tutorial
- robot_state_publisher:
  https://github.com/ros/robot_state_publisher
- joint_state_publisher (incl. joint_state_publisher_gui):
  https://github.com/ros/joint_state_publisher
- Docker Compose v2 spec — `init`, `network_mode`, `volumes`, etc.:
  https://docs.docker.com/reference/compose-file/
- tini (PID 1 init that `init: true` injects):
  https://github.com/krallin/tini

## Why the pattern changed (read before editing files)

Phase 3 used a single shared router + clients (`mode="client"` on
every non-router service). That worked but was a workaround. Three
findings from primary-source research justify the change:

1. **rmw_zenoh's default session config (`mode="peer"`,
   `listen.endpoints: ["tcp/localhost:0"]`,
   `connect.endpoints: ["tcp/localhost:7447"]`,
   `scouting.multicast.enabled: false`,
   `scouting.gossip.enabled: true`) is designed for the single-host
   case**: a router and its ROS 2 nodes colocated in one network
   namespace, sharing loopback. Sessions advertise loopback-only
   listen addresses, which the router gossips to other sessions in
   the same namespace. Peer-to-peer connections form over loopback
   after discovery. See:
   `rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5:12,44-46,96-98,143,176`.

2. **rmw_zenoh README explicitly prescribes "router per fault
   domain, federate routers" for multi-host deployment** (which in
   Docker terms means multi-netns). README § "Connecting multiple
   hosts":
   > To bridge communications across two or more hosts, the Zenoh
   > router configuration for one of the hosts must be updated to
   > connect to the other host's Zenoh router at startup.

3. **The peer-to-peer-survives-router-death resilience property**
   (peers maintain established connections after router failure)
   only holds in peer mode. Client mode loses it. The router config
   itself comments on this design intent:
   `rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5:237-239`
   > peers_failover_brokering: false
   > ROS setting: disabled by default because it serves no purpose
   > when each peer connects directly to all others.

The new pattern therefore puts each container in its own fault
domain: each container runs both a router and its ROS 2 process
group, the router and process group share loopback (same container
= same netns), rmw_zenoh defaults apply unchanged to the ROS 2
processes, and the two routers federate via a one-direction
`connect/endpoints` override on the dev side.

## Architecture (read second)

```
                 host LAN ──── port-publish 7447 ────┐
                                                     │
                                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│ px100-net (Docker user-defined bridge)                             │
│                                                                    │
│ ┌───────────────────────────┐    ┌─────────────────────────────┐  │
│ │ robot container           │    │ dev container               │  │
│ │ image: px100-robot:dev    │    │ image: px100-dev:dev        │  │
│ │ init: true                │    │ init: true                  │  │
│ │ ports: 7447:7447          │    │ env: ZENOH_ROUTER_OVERRIDE= │  │
│ │                           │    │      'connect/endpoints=    │  │
│ │ ┌───────────────────────┐ │    │       ["tcp/robot:7447"]'   │  │
│ │ │ rmw_zenohd (bg)       │◄┼────┼─┐                           │  │
│ │ │ default router config │ │    │ │ ┌─────────────────────┐   │  │
│ │ └───────────────────────┘ │    │ └►│ rmw_zenohd (bg)     │   │  │
│ │           ▲ localhost     │    │   │ override applied    │   │  │
│ │           │ :7447         │    │   │ via entrypoint      │   │  │
│ │ ┌─────────┴───────────┐   │    │   └──┬──────────────────┘   │  │
│ │ │ robot_state_        │   │    │      │ localhost            │  │
│ │ │ publisher (fg)      │   │    │      │ :7447                │  │
│ │ │ peer, defaults      │   │    │   ┌──┴───────────────────┐  │  │
│ │ │ pubs /tf, /robot_   │   │    │   │ joint_state_publisher│  │  │
│ │ │ description         │   │    │   │ _gui (bg) — peer,    │  │  │
│ │ │ subs /joint_states  │   │    │   │ defaults; pubs       │  │  │
│ │ └─────────────────────┘   │    │   │ /joint_states        │  │  │
│ │                           │    │   ├──────────────────────┤  │  │
│ │                           │    │   │ rviz2 (fg) — peer,   │  │  │
│ │                           │    │   │ defaults; subs /tf + │  │  │
│ │                           │    │   │ /robot_description   │  │  │
│ │                           │    │   └──────────────────────┘  │  │
│ └───────────────────────────┘    └─────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

Topic flow across the federation:

- `/joint_states`: dev (`joint_state_publisher_gui`) → dev-router →
  robot-router (federated) → robot (`robot_state_publisher`)
- `/tf`, `/robot_description`: robot (`robot_state_publisher`) →
  robot-router → dev-router (federated) → dev (`rviz2`)

Bidirectional flow proves federation works in both directions, not
just one.

## Key design decisions in the entrypoint

The image's entrypoint (`docker/entrypoint.sh`, created in Step 2):

1. Sources `/opt/ros/${ROS_DISTRO}/setup.bash` (replaces the OSRF
   base image's `/ros_entrypoint.sh` behaviour).
2. Starts `rmw_zenohd` in the background, **inheriting any
   `ZENOH_CONFIG_OVERRIDE` env var set on the container** — this
   is how the dev-router gets its federation override.
3. **Unsets `ZENOH_CONFIG_OVERRIDE` before running the main
   command**. This is the critical scoping step. Without the unset,
   the same override would apply to the ROS 2 node's session config
   too, breaking the topology by making the node skip its local
   router. We want the override on the router only.
4. Installs a trap to kill the router on exit (signal-clean
   shutdown via tini, which `init: true` provides).
5. Runs the main command in the foreground (not via `exec` — so the
   trap fires on exit).

This sidesteps the alternative of shipping a full copy of the 230-line
`DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5` per container, which would
introduce an upstream-sync burden.

## Step 0 — Inventory before edit

Per the project's "inventory before install" convention, capture
current state so the verification step has a baseline.

```
cd ~/<your-project-root>/pincherx-100-docker-lyrical
docker images px100-base
docker ps -a
docker network ls | grep px100
git status
git log --oneline -5
```

Note any unexpected containers, networks, or uncommitted files.
Stop and clean any leftovers from Phase 3 verification:

```
docker compose --profile verify down --remove-orphans
docker compose --profile adhoc down --remove-orphans
```

## Step 1 — Update the Dockerfile

Open the file:

```
nano docker/Dockerfile
```

Replace its content with:

```dockerfile
# syntax=docker/dockerfile:1.6
#
# Parameterized image for the PincherX-100 Docker-Lyrical project.
#
# BASE_IMAGE selects the upstream ROS 2 image tier:
#   - ros:lyrical-ros-base-resolute          (robot — headless)
#   - osrf/ros:lyrical-desktop-full-resolute  (dev — rviz + GUI)
#
# The upstream ROS Docker images live under two Docker Hub namespaces:
#   library/ros  — Docker Official Images (ros-core, ros-base, perception)
#   osrf/ros     — OSRF profile (desktop, desktop-full, simulation)
#
# EXTRA_PKGS adds per-role apt packages (space-separated).
#
# Build examples:
#   docker compose build                     # both images at once
#
#   # Or individually:
#   docker buildx build \
#     --build-arg BASE_IMAGE=ros:lyrical-ros-base-resolute \
#     --build-arg EXTRA_PKGS=ros-lyrical-urdf-tutorial \
#     -t px100-robot:dev --load docker/
#
#   docker buildx build \
#     --build-arg BASE_IMAGE=osrf/ros:lyrical-desktop-full-resolute \
#     --build-arg "EXTRA_PKGS=ros-lyrical-urdf-tutorial ros-lyrical-joint-state-publisher-gui" \
#     -t px100-dev:dev --load docker/

ARG BASE_IMAGE=osrf/ros:lyrical-desktop-full-resolute
FROM ${BASE_IMAGE}

ARG ROS_DISTRO=lyrical
ARG EXTRA_PKGS=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
        ${EXTRA_PKGS} \
 && rm -rf /var/lib/apt/lists/*

ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

COPY entrypoint.sh /px100-entrypoint.sh
RUN chmod +x /px100-entrypoint.sh

ENTRYPOINT ["/px100-entrypoint.sh"]
```

Save and exit (Ctrl+O, Enter, Ctrl+X).

## Step 2 — Create the entrypoint script

Open the file:

```
nano docker/entrypoint.sh
```

Paste:

```bash
#!/bin/bash
# Image entrypoint for the px100-robot and px100-dev images.
#
# Starts rmw_zenohd in the background alongside the main process,
# and scopes ZENOH_CONFIG_OVERRIDE to the router so the main
# process (and any ROS 2 nodes it spawns) loads rmw_zenoh's
# default session config unchanged.
#
# Sequence:
#   1. Source ROS 2 setup (replaces /ros_entrypoint.sh behaviour).
#   2. Start rmw_zenohd in the background, inheriting any
#      ZENOH_CONFIG_OVERRIDE env var set on the container (so the
#      router's connect.endpoints can be overridden for federation).
#   3. Unset ZENOH_CONFIG_OVERRIDE so the main process sees an
#      unmodified env. Without this, the same override would apply
#      to the ROS 2 node's session config too.
#   4. Install a trap to kill the router on shell exit.
#   5. Sleep briefly so the router binds :7447 before the main
#      process tries to connect.
#   6. Run the main command in the foreground (no exec; the trap
#      fires on shell exit).
#
# Container lifetime is tied to the main command. When the main
# command exits, the trap kills the router and the shell exits;
# tini (PID 1, injected by `init: true` in compose) reaps any
# stragglers and the container stops.

set -e

source "/opt/ros/${ROS_DISTRO}/setup.bash"

# Start the router, inheriting ZENOH_CONFIG_OVERRIDE if set.
ros2 run rmw_zenoh_cpp rmw_zenohd &
ROUTER_PID=$!

cleanup() {
  kill "$ROUTER_PID" 2>/dev/null || true
  wait "$ROUTER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Scope: from here onward, ZENOH_CONFIG_OVERRIDE is not visible to
# the main command.
unset ZENOH_CONFIG_OVERRIDE

# Give the router a moment to bind its listen socket. rmw_zenoh
# session default ZENOH_ROUTER_CHECK_ATTEMPTS=1 means a single
# retry with a ~1s gap before the session gives up and proceeds
# without a router.
sleep 1

"$@"
```

Save and exit. Make executable:

```
chmod +x docker/entrypoint.sh
```

## Step 3 — Replace compose.yaml

> **Why compose.yaml comes before the build:** `docker compose build`
> reads its build configuration (image names, `BASE_IMAGE` and
> `EXTRA_PKGS` args) from compose.yaml. The compose.yaml must be in
> place before the build step.

Open the file:

```
nano compose.yaml
```

Replace its content with:

```yaml
# compose.yaml — Phase 4 topology proof.
#
# Two-container, two-router, federated topology. Robot uses ros-base
# (headless); dev uses desktop-full (rviz + GUI). Both built from
# the same parameterized Dockerfile with different BASE_IMAGE and
# EXTRA_PKGS args. See runbook/04-topology-proof-urdf-tutorial.md.
#
# Usage:
#   docker compose build        # build both images
#   xhost +local:docker         # allow containers to reach XWayland
#   docker compose up           # brings up both containers
#   docker compose down         # tears down
#
# Ad-hoc topic inspection from outside both containers:
#   docker compose exec robot bash -c "source /opt/ros/lyrical/setup.bash && ros2 topic list"
#   docker compose exec dev   bash -c "source /opt/ros/lyrical/setup.bash && ros2 topic echo /joint_states --once"

name: px100

networks:
  default:
    name: px100-net

x-build-common: &build-common
  context: ./docker
  dockerfile: Dockerfile

# XWayland display env for the dev container. On Resolute, DISPLAY
# points to XWayland (auto-started by the Wayland compositor), not a
# standalone Xorg. rviz2 forces xcb automatically; QT_QPA_PLATFORM
# is set here for explicitness.
x-xwayland: &xwayland
  DISPLAY: ${DISPLAY:-:0}
  QT_QPA_PLATFORM: xcb

services:
  robot:
    image: px100-robot:dev
    build:
      <<: *build-common
      args:
        BASE_IMAGE: ros:lyrical-ros-base-resolute
        EXTRA_PKGS: ros-lyrical-urdf-tutorial
    container_name: robot
    init: true
    ports:
      - "7447:7447"
    command:
      - bash
      - -c
      - |
        source /opt/ros/lyrical/setup.bash
        URDF=/opt/ros/lyrical/share/urdf_tutorial/urdf/06-flexible.urdf
        ros2 run robot_state_publisher robot_state_publisher \
          --ros-args -p robot_description:="$$(cat $$URDF)"

  dev:
    image: px100-dev:dev
    build:
      <<: *build-common
      args:
        BASE_IMAGE: osrf/ros:lyrical-desktop-full-resolute
        EXTRA_PKGS: "ros-lyrical-urdf-tutorial ros-lyrical-joint-state-publisher-gui"
    container_name: dev
    init: true
    depends_on:
      - robot
    environment:
      <<: *xwayland
      ZENOH_CONFIG_OVERRIDE: 'connect/endpoints=["tcp/robot:7447"]'
    devices:
      - /dev/dri:/dev/dri                   # GPU access for rviz2
    volumes:
      - /tmp/.X11-unix:/tmp/.X11-unix:rw  # XWayland socket
    command:
      - bash
      - -c
      - |
        source /opt/ros/lyrical/setup.bash
        ros2 run joint_state_publisher_gui joint_state_publisher_gui &
        GUI_PID=$$!
        trap "kill $$GUI_PID 2>/dev/null || true" EXIT
        rviz2
```

Save and exit.

> Why the `$$` doublings: docker compose's YAML interpolation strips
> a single `$` (it uses `${VAR}` for compose-level variable
> substitution). `$$` escapes the dollar sign so bash receives the
> literal `$VAR` it needs. Forgetting this causes baffling
> "unbound variable" errors at runtime.

## Step 4 — Build both images

```
docker compose build
```

This builds two images from the same Dockerfile with different
build args (defined in compose.yaml):

| Image | BASE_IMAGE | EXTRA_PKGS | Size |
|---|---|---|---|
| `px100-robot:dev` | `ros:lyrical-ros-base-resolute` | `ros-lyrical-urdf-tutorial` | ~400 MB |
| `px100-dev:dev` | `osrf/ros:lyrical-desktop-full-resolute` | `ros-lyrical-urdf-tutorial ros-lyrical-joint-state-publisher-gui` | ~2 GB |

Expected: first build pulls both base images and runs apt; a few
minutes total. Subsequent builds with no changes finish in seconds
via BuildKit layer cache.

Verify both images:

```
docker images px100-robot
docker images px100-dev
```

Verify entrypoint is in the robot image:

```
docker run --rm --entrypoint cat px100-robot:dev /px100-entrypoint.sh | head -5
docker image inspect px100-robot:dev --format '{{.Config.Entrypoint}}'
```

Expected: the head shows the shebang + first comment lines; the
inspect output shows `[/px100-entrypoint.sh]`.

Verify ros-base contents in the robot image (no rviz, yes
robot_state_publisher):

```
docker run --rm px100-robot:dev bash -c 'which rviz2 || echo "no rviz2 (expected)"; which robot_state_publisher'
```

Expected: "no rviz2 (expected)" and
`/opt/ros/lyrical/bin/robot_state_publisher`.

## Step 5 — Host-side display preparation (XWayland)

Ubuntu 26.04 Resolute runs a Wayland-only compositor (GNOME 50
dropped its X11 backend; KDE Plasma defaults to Wayland). There is
no standalone Xorg session. However, **rviz2 cannot run on native
Wayland** — it has three independent X11 hard dependencies:

1. `rviz2/src/main.cpp` detects Wayland and forces `-platform xcb`
   (https://github.com/ros2/rviz/pull/1253).
2. `rviz_rendering/render_system.cpp` directly calls X11/GLX APIs
   (`XOpenDisplay`, `glXChooseVisual`, `glXCreateContext`).
3. The vendored OGRE 1.12.10 has no Wayland render path (added in
   OGRE 14.3.0+; rviz hasn't adopted it; tracked at
   https://github.com/ros2/rviz/issues/847).

The working path is **XWayland**: the `xwayland` package (section
`main`, installed by default on Resolute) provides an X11
compatibility server that the Wayland compositor auto-starts. From
the container's perspective, it is indistinguishable from a
standalone X server — same `DISPLAY` env var, same
`/tmp/.X11-unix` socket.

`joint_state_publisher_gui` is pure Qt (no OGRE) and could run on
native Wayland, but shares the xcb setting with rviz2 for
simplicity.

### Pre-flight: verify XWayland is running

```
echo "DISPLAY=$DISPLAY"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
ls -la /tmp/.X11-unix/
```

Expected:

- `DISPLAY=:0` (or `:1` — the XWayland display number).
- `WAYLAND_DISPLAY=wayland-0` (confirms a Wayland session).
- `/tmp/.X11-unix/X0` (or `X1`) exists as a socket file.

If `DISPLAY` is unset or the socket is missing, XWayland has not
started yet. On GNOME 40+ (including Resolute), XWayland starts
on-demand when the first X11 client needs it. Launch any X11 app
on the host (e.g. `xeyes &`) to trigger it, then re-check.

### Grant container access to XWayland

```
xhost +local:docker
```

Expected output:

```
non-network local connections being added to access control list
```

> **How this works on Resolute**: `xhost` controls access to the
> **XWayland** server (not a standalone Xorg — there isn't one).
> The Wayland compositor itself has no `xhost` equivalent; its
> access control is filesystem-based (the Wayland socket at
> `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` is mode `0700`, owned by
> your UID). Since rviz2 uses the X11/xcb path, `xhost` is what
> matters here.
>
> `+local:docker` grants access to local connections from the
> `docker` group — tighter than `xhost +` (which allows the
> world). Re-run after each host reboot or compositor restart.

## Step 6 — Bring up the topology

```
docker compose up
```

Expected sequence in the log stream (interleaved between services):

1. `robot` container starts. Entrypoint sources ROS, starts
   rmw_zenohd, sleeps 1s, then launches `robot_state_publisher`.
2. `dev` container starts (after `depends_on` releases). Entrypoint
   sources ROS, starts rmw_zenohd **with** the federation override,
   sleeps 1s, then launches `joint_state_publisher_gui` (background)
   and `rviz2` (foreground).
3. Within a few seconds:
   - `rmw_zenohd` on `dev` logs a successful connection to `tcp/robot:7447`.
   - `robot_state_publisher` on `robot` logs "got segment ..." messages
     as it processes the URDF.
   - XWayland displays two windows from the dev container: the
     `joint_state_publisher_gui` slider panel and the `rviz2` 3D viewer.

If the rviz2 window does not open, see the Watch-outs section.

## Step 7 — Verify

Visual verification (the load-bearing test):

1. In the `joint_state_publisher_gui` window, locate the joint
   sliders for the `06-flexible.urdf` model. Move one slider.
2. **Expected**: the model in the `rviz2` window updates in real time
   to reflect the new joint angle.

This proves: `/joint_states` propagated dev → dev-router →
robot-router → robot (consumed by robot_state_publisher), and `/tf` +
`/robot_description` propagated robot → robot-router → dev-router →
dev (consumed by rviz2). Bidirectional flow across the federation
end-to-end.

If `rviz2` doesn't show the model on first open, set the Fixed Frame
in the left panel to `base_link` (or whatever the URDF's root link is
named) and re-add a `RobotModel` display with topic `/robot_description`.

CLI verification (in a separate terminal, with the topology up):

```
# Topics flowing through robot's router:
docker compose exec robot bash -c "
  source /opt/ros/lyrical/setup.bash &&
  ros2 topic list
"

# Joint states actively published:
docker compose exec dev bash -c "
  source /opt/ros/lyrical/setup.bash &&
  ros2 topic echo /joint_states --once
"

# tf actively published:
docker compose exec robot bash -c "
  source /opt/ros/lyrical/setup.bash &&
  ros2 topic echo /tf --once
"

# Federation health (router log inspection):
docker compose logs robot | grep -i zenoh | head -20
docker compose logs dev | grep -i zenoh | head -20
```

Expected:
- `ros2 topic list` from either container shows at least
  `/joint_states`, `/robot_description`, `/tf`,
  `/tf_static`, plus the standard `/parameter_events`, `/rosout`.
- `ros2 topic echo /joint_states --once` returns a `sensor_msgs/msg/JointState`
  payload with joint names and positions.
- `ros2 topic echo /tf --once` returns a `tf2_msgs/msg/TFMessage` payload.
- The dev-side router log contains a line indicating the federation
  link to `tcp/robot:7447` was established.

## Step 8 — Shut down cleanly

In the terminal running `docker compose up`, press Ctrl+C. Compose
sends SIGTERM to each container. The entrypoint's trap fires, kills
rmw_zenohd, and exits.

Verify nothing is left running:

```
docker compose down
docker ps -a | grep -E "robot|dev|px100"   # should be empty
docker network ls | grep px100             # only px100-net if not removed
```

Cleanup:

```
xhost -local:docker                        # revoke XWayland access grant
```

## Step 9 — Commit

Verify the changed files:

```
git status
git diff
```

Expected: changes to `docker/Dockerfile`, new `docker/entrypoint.sh`,
changes to `compose.yaml`, changes to `CLAUDE.md`, new
`runbook/04-topology-proof-urdf-tutorial.md`.

Commit:

```
git add docker/Dockerfile docker/entrypoint.sh compose.yaml \
        CLAUDE.md runbook/04-topology-proof-urdf-tutorial.md
git commit -m "Phase 4 — topology proof with urdf_tutorial

Replace Phase 3's client-mode workaround with the rmw_zenoh-canonical
router-per-fault-domain pattern. Each container now runs rmw_zenohd
alongside its main process group, sharing loopback so ROS 2 nodes
use rmw_zenoh defaults unchanged. Federation via one-direction
connect/endpoints override on the dev-side router, applied through
ZENOH_CONFIG_OVERRIDE and scoped by the new entrypoint.

Split the single-image approach into role-specific images: robot
container on ros:lyrical-ros-base-resolute (headless, ~324 MB base),
dev container on osrf/ros:lyrical-desktop-full-resolute (rviz + GUI).
Both built from the same parameterized Dockerfile via BASE_IMAGE and
EXTRA_PKGS build args.

Demonstrates bidirectional topic flow across the federation:
/joint_states (dev -> robot) and /tf + /robot_description
(robot -> dev), verified visually with rviz2 + joint_state_publisher_gui
driving urdf_tutorial's 06-flexible.urdf model.

Robot-side router published on host port 7447 in preparation for
the Phase-8 Flutter-from-phone case."

git push
```

## Watch-outs

- **`xhost +local:docker` is per-session.** Re-run after every host
  reboot or compositor restart. If rviz2 fails with "Could not
  connect to display :0," this is the most likely cause.
- **rviz2 requires XWayland, not native Wayland.** Three independent
  blockers (main.cpp xcb override, rviz_rendering GLX calls, OGRE
  1.12.10) prevent native Wayland. `QT_QPA_PLATFORM=xcb` in compose
  is for explicitness; rviz2 forces xcb automatically when it
  detects `XDG_SESSION_TYPE=wayland`. XWayland is installed by
  default on Resolute (`xwayland` package, `main` section) and
  auto-started by the compositor; no standalone Xorg is needed.
- **XWayland on-demand startup.** On GNOME 40+ (Resolute default),
  XWayland may not start until the first X11 client launches. If
  `$DISPLAY` is unset or `/tmp/.X11-unix/X0` is missing before
  `docker compose up`, launch any X11 app on the host (e.g.
  `xeyes &`) to trigger XWayland, then re-check. KDE Plasma
  typically starts XWayland at session login regardless.
- **`ZENOH_CONFIG_OVERRIDE` scoping is in the entrypoint, not the
  shell**. If a future operator runs `docker compose exec dev bash`
  and starts a ROS 2 node manually, the env var is in the shell's
  environment (since compose set it on the container). The node
  would then mis-route through `tcp/robot:7447` directly, bypassing
  the local dev router. Manual workaround: `unset
  ZENOH_CONFIG_OVERRIDE` before launching any ROS 2 node from an
  exec'd shell.
- **`init: true` is load-bearing.** Without tini as PID 1, the
  entrypoint's bash becomes PID 1 and inherits non-trivial signal
  handling responsibilities (zombie reaping, SIGTERM forwarding).
  Omitting `init: true` makes Ctrl+C shutdowns unreliable.
- **`depends_on` is start-order only, not health-aware.** `dev`
  starts after `robot` starts, but doesn't wait for `robot`'s router
  to be ready. The entrypoint's `sleep 1` covers the typical case;
  if you see federation connection retries in the dev log, increase
  the sleep or add a healthcheck on the robot service.
- **The robot URDF is hardcoded to `06-flexible.urdf`** in the
  compose command. To swap models, edit the `URDF=` line. Other
  options shipped by `urdf_tutorial`:
  `01-myfirst.urdf` (single cylinder, no joints — won't demonstrate
  joint state flow), `02-multipleshapes.urdf`,
  `03-origins.urdf`, `04-materials.urdf`, `05-visual.urdf`,
  `06-flexible.urdf`, `07-physics.urdf`. For `08-macroed.urdf.xacro`,
  pipe through `xacro` first: `URDF_XML=$(xacro
  /opt/ros/lyrical/share/urdf_tutorial/urdf/08-macroed.urdf.xacro)`.
- **`$$` in compose.yaml command blocks** must be literal-`$`-escapes,
  not single `$`. Forgetting this is a frequent source of
  "unbound variable" errors when bash subshells run.
- **The robot container's published port 7447 is unused this phase.**
  No external client connects in Phase 4. The port-publish is there
  to make Phase 4's compose forward-compatible with Phase 8
  (Flutter-from-phone). Removing it for Phase 4 is fine if you'd
  prefer to add it back later.
- **`urdf_tutorial` comes from `ros2-testing` apt repo in the OSRF
  image**, not from the stable `packages.ros.org/ros2` repo. This is
  the same situation Phase 2 documented for `rmw_zenoh_cpp`. Switch
  to a stable repo when one is published for Lyrical.

## Extras

### What this DOESN'T validate (for the next phases to address)

- USB device pass-through (`--device=/dev/ttyDXL:/dev/ttyDXL`) —
  Phase 5 covers it, including the Docker symlink-resolution gotcha
  (`--device` resolves symlinks to targets, so `/dev/ttyDXL` arrives
  as `/dev/ttyUSB0` inside the container; xs_sdk hardcodes the
  `/dev/ttyDXL` path).
- Trossen workspace built from the patched installer fork — Phase 5.
- Real arm motion via xs_sdk publishing `/px100/joint_states` —
  Phase 5.
- LAN exposure of the Zenoh router to a non-Docker host (the
  phone) — Phase 8. The port publishing on `robot:7447` is already
  in place; what's missing is the router-side override to advertise
  a LAN-reachable locator (rather than the bridge IP) via gossip.
  Decide that override when Phase 8 begins, against the rmw_zenoh
  README's "Connecting multiple hosts" example.

### Alternative URDF source: the real px100

An optional Phase 4a slice — use the `interbotix_xsarm_descriptions`
URDF for the PincherX-100 instead of `urdf_tutorial`'s generic
models. Requires the patched Trossen workspace to be built first
(currently scheduled for Phase 5). Would visually validate that
rviz2 renders the actual px100 URDF, separately from validating
that xs_sdk drives it.

### Project memories to refresh after this phase verifies

These were captured before today's primary-source research pass and
are now stale or inaccurate:

- `project_docker_zenoh_config_pattern` — captures the
  client-mode-with-shared-router pattern from Phase 3 as if it were
  THE pattern. Should be revised to present three valid patterns
  (A: router per netns + federation — used in this phase; B: shared
  router + reachable peers; C: shared router + clients — used in
  Phase 3) with the rmw_zenoh defaults as the canonical baseline.
- `project_docker_lyrical_research_2026_05_23` — contains
  outdated "single image base + client mode" architecture decisions
  and the incorrect "zenoh-dart does not exist" claim. The
  zenoh-dart binding exists in the user's GitHub at
  `hugo-bluecorn/zenoh_dart` and is already used in production by
  the `zenoh-counter-flutter` template.
- A new memory should capture the rmw_zenoh ROS-canonical pattern
  with primary-source citations from the research pass.
