# Docker architecture research for PincherX-100 on ROS 2 Lyrical Luth

Date: 2026-05-23

Primary-source research synthesis produced before Phase-0 of the
containerized PincherX-100 runbook. Five parallel research passes
against canonical upstream docs (Docker, ROS 2, Eclipse Zenoh,
kernel.org, Mesa, NVIDIA, OSRF). All citations link to primary
upstream; no third-party blogs.

## TL;DR — what changed because of this research

1. **`ros-lyrical-rmw-zenoh-cpp` is in apt on Ubuntu 26.04 Resolute.**
   No source build needed. ([packages.ros.org][packages-ros])
2. **OSRF official Docker images for Lyrical already exist.**
   `osrf/ros:lyrical-desktop-resolute` is the rviz-capable base.
   ([osrf/docker_images][osrf-docker-images])
3. **Zenoh discovery is TCP-unicast, not multicast.** Default
   session connects to `tcp/localhost:7447`; default router binds
   `tcp/[::]:7447`. Cross-container discovery works on a
   user-defined Docker bridge — no `--network=host` required, no
   DDS-multicast-across-netns headaches.
   ([rmw_zenoh router config][zenoh-router-config])
4. **rmw_zenoh requires a `rmw_zenohd` router process by default.**
   Peer-mode is possible via `ZENOH_ROUTER_CHECK_ATTEMPTS=-1` plus
   `scouting/multicast/enabled=true`, but the documented happy path
   is router-mediated. ([rmw_zenoh README][rmw-zenoh-readme])
5. **`zenoh-dart` does not exist** in the `eclipse-zenoh` GitHub
   org. A Flutter client (Phase-7-equivalent) must go through
   `zenoh-pico` FFI or a community Dart binding. **Project-level
   risk; flag for later.** ([eclipse-zenoh org][eclipse-zenoh-org])
6. **`--device=/dev/ttyDXL` resolves the symlink to its target.**
   The container sees `/dev/ttyUSB0`, not `/dev/ttyDXL`. Since the
   Trossen `xs_sdk` has `PORT=/dev/ttyDXL` hardcoded
   (`xs_sdk_obj.h:22`), we either patch the SDK, override at
   launch, or recreate the symlink inside the container.
   ([Docker 1.11.0 release notes][docker-1.11-release-notes])
7. **udev runs on the host only.** Trossen's
   `99-interbotix-udev.rules` must be installed on the host; the
   rule's `ATTR{latency_timer}="1"` writes to sysfs, persists for
   the lifetime of the device binding, and is correctly inherited
   by the container's open file descriptor. Same install pattern
   as the QEMU runbook's Phase-4.
8. **rviz2 on Wayland forces XWayland.** Ubuntu 26.04's default
   GNOME session is Wayland-only. Even on a Wayland host,
   bind-mount `/tmp/.X11-unix` for the XWayland socket.
   ([ros2/rviz#1253][rviz-pr-1253])
9. **OSRF `rocker` exists.** Wraps `docker run` with extensions
   for `--x11`, `--nvidia`, `--cuda`, `/dev/dri`, `--device`, and
   user-UID mapping. Strongly suggests the bare-`docker run` path
   has enough friction that the community built a tool around it.
   ([osrf/rocker][osrf-rocker])
10. **No NVIDIA Container Toolkit needed for rviz-on-iGPU.** Plain
    `--device=/dev/dri/renderD128` + Mesa userspace in the image
    is sufficient. Toolkit is only needed if we want CUDA, NVENC,
    or NVIDIA-OpenGL (i.e., dGPU compute path).
    ([NVIDIA install guide][nvidia-toolkit])

## Context

The PincherX-100 Humble runbook (the parent project of this fork)
ran the ROS 2 control stack in a QEMU/KVM guest. Phase-5 hardware
verification surfaced that virtio-gpu's `obj_free_work` workqueue
stalls under rviz cause ~50× SyncRead error amplification on the
Dynamixel motor bus, and the workqueue stall is not fixed in any
Linux kernel through v6.14. The Lyrical fork pivots away from the
QEMU/KVM architecture entirely: ROS 2 lives in Docker containers
on a bare-metal Ubuntu 26.04 Resolute host. ROS 2 Lyrical Luth is
the target distro (REP-2000 Tier-1 on Resolute).

This document captures the architectural research that informs
Phase-0 of the runbook. It does **not** prescribe the runbook
itself; that lands in subsequent commits.

## Area 1 — Docker container runtime fundamentals

### What `--device` does

`docker run --device=/host/path` adds the device node to the
container's cgroup allow set (rwm: read/write/mknod by default;
overridable). The container does NOT receive a bind-mount of the
host's `/dev` — it gets its own minimal devtmpfs-like view
populated only by the devices we explicitly grant.
([docker container run reference][docker-run-ref])

Under cgroup v2 (Ubuntu unified hierarchy since 21.10), device
restrictions are enforced by an eBPF program attached at
`BPF_CGROUP_DEVICE`; runc handles this transparently. Behavior is
equivalent to cgroup v1's `devices.allow` from the user's
perspective. ([kernel.org cgroup-v2][kernel-cgroup-v2])

### What `--device` does NOT do

Unlike libvirt's `<hostdev managed='yes'>`, Docker does **not**
unbind the host driver before handing the device to the container.
Both host and container can have file descriptors open on the same
node simultaneously. This is fundamentally different from the
"detach, hand over, reattach" semantics of the QEMU runbook's
Phase-4. For a USB-serial device opened by exactly one process at
a time, this is a non-issue; it would be one if the host had a
service holding the FT232H open.

### Hot-plug

Devices assigned via `--device` are static at container creation
time. If the U2D2 disconnects and reconnects, the container does
NOT automatically re-acquire the new minor number. Workaround:
`--device-cgroup-rule='c 188:* rmw'` whitelists a major:minor
class. ([docker container run reference][docker-run-ref])

This is a regression compared to libvirt's managed mode, which
re-attaches automatically. Not a blocker for development work but
worth documenting in the runbook as an operational quirk.

### `--privileged`

Disables seccomp/AppArmor profiles, enables all capabilities,
grants access to all host devices, mounts `/sys` and cgroup
hierarchies read-write. Docs label it "unsandboxed." Community
robotics tutorials often reach for `--privileged` as a sledgehammer
for USB + GPU access; we should not — the granular
`--device=/dev/dri/renderD128 --device=/dev/ttyDXL` pattern works
and preserves the rest of the sandbox.

### Image strategy

- Pin base image by tag for development (`osrf/ros:lyrical-desktop-resolute`),
  by digest for reproducible releases.
- Order Dockerfile layers from rarely-changing to often-changing:
  base, apt repos + apt-update+install (single RUN), then Trossen
  installer, then workspace clone, finally `colcon build`.
  Caching at each boundary reduces iteration time on the
  installer-patching loop. ([docker build cache][docker-cache])

### Real-time

Docker exposes `--cpu-rt-runtime` / `--cpu-rt-period` for
real-time scheduling, requiring `CONFIG_RT_GROUP_SCHED` in the
host kernel. Not relevant at PincherX-100 control rates (100 Hz)
but documented as an escalation path.
([docker resource constraints][docker-resource-constraints])

## Area 2 — ROS 2 Lyrical in Docker

### OSRF official images

The official `library/ros` Docker Hub repo and the broader
`osrf/ros` repo both already publish Lyrical tags as of
~2026-05-09:

| Tag | Source | Variant |
|---|---|---|
| `lyrical`, `lyrical-ros-core[-resolute]` | `library/ros` | ros-core (minimal) |
| `lyrical-ros-base[-resolute]` | `library/ros` | ros-base (default) |
| `lyrical-perception[-resolute]` | `library/ros` | perception (PCL/image) |
| `lyrical-desktop[-resolute]` | `osrf/ros` | desktop (rviz, demos) |
| `lyrical-desktop-full[-resolute]` | `osrf/ros` | desktop-full |
| `lyrical-simulation[-resolute]` | `osrf/ros` | simulation (Gazebo) |

The `library/ros` repo deliberately omits `desktop*` variants per
upstream OSRF policy; rviz-capable images live on `osrf/ros`.
([osrf/docker_images][osrf-docker-images],
[hub.docker.com/r/osrf/ros][osrf-ros-tags])

Canonical Dockerfile skeleton (from
`osrf/docker_images/ros/lyrical/ubuntu/resolute/ros-core/Dockerfile`):

```dockerfile
FROM ubuntu:resolute
# apt prereqs (ca-certificates curl dirmngr gnupg2 lsb-release)
# Add ROS 2 apt source + GPG key
# ENV ROS_DISTRO=lyrical
# apt install ros-lyrical-ros-core=0.13.0-3*
# COPY ros_entrypoint.sh /
# ENTRYPOINT ["/ros_entrypoint.sh"]
# CMD ["bash"]
```

### Apt-package availability on Resolute

`packages.ros.org/ros2/ubuntu/dists/resolute/main/binary-amd64/Packages.gz`
contains 1989 packages, of which 1912 are `ros-lyrical-*`. Spot-checked
present: `ros-lyrical-{ros-core,ros-base,desktop,desktop-full,perception,
rviz2,rmw-fastrtps-cpp,rmw-cyclonedds-cpp,rmw-zenoh-cpp}`. No
`ros-lyrical-interbotix-*` — Trossen ships source-only.
([packages.ros.org Resolute][packages-ros])

Note: the `packages.ros.org` TLS certificate is invalid for that
hostname; HTTPS errors. The OSUOSL mirror serves over plain HTTP.
Pinning APT to HTTP is acceptable for ROS-distro packages because
the apt-key/dpkg-sig chain verifies the package signatures
independently of TLS.

### Trossen installer behavior in a Docker RUN step

Inspection of
`git/interbotix_ros_manipulators/interbotix_ros_xsarms/install/amd64/xsarm_amd64_install.sh`
(local clone, pinned to the `main` branch at the time of writing):

| Concern | Status |
|---|---|
| `ALL_VALID_DISTROS=('melodic' 'noetic' 'galactic' 'humble' 'rolling')` | Hard-fails on `lyrical`; patch required |
| `JAMMY_VALID_DISTROS=('humble' 'rolling')` | Hard-fails on Resolute; patch required |
| `check_ubuntu_version` hard-coded to 18.04/20.04/22.04 | Patch required |
| Hard-coded branch `git clone -b "$ROS_DISTRO_TO_INSTALL"` | No `lyrical` branch upstream; pin to `jazzy` SHA or fork |
| `sudo` usage throughout | No-op or error in Dockerfile RUN (root by default); strip or install `sudo` |
| `-n` flag for non-interactive runs | **Explicitly documented for Docker builds (line 50)** |
| `sudo cp 99-interbotix-udev.rules /etc/udev/rules.d/` | No-op against host kernel; install on host instead |
| `sudo udevadm control --reload-rules && sudo udevadm trigger` | No-op in container; do on host |
| `usermod -aG dialout` | **Not in this script** — clean |
| `apt install ros-<distro>-desktop` | Succeeds without DISPLAY; pure apt operation |
| `$DISPLAY` checks | None — installer is headless-clean |
| `systemd` assumption | None |
| `sudo pip3 install transforms3d` (L160) | **Fails on PEP 668 (Resolute)**; patch to venv pattern |
| `python3 -m pip install modern_robotics` (L167) | **Fails on PEP 668 (Resolute)**; patch to venv pattern |

The PEP 668 fix is structurally the same as the Humble project's
Phase-5 "Step 0 — Python development environment" — install
`python3-full`, create a venv with `--system-site-packages`, pip
into the venv, ship an `activate.sh` wrapper. See the Humble
project's `runbook/05-connection-verification.md` for the
hand-applied pattern; the Lyrical Docker installer should
automate this.

### `rocker` — relevant?

`osrf/rocker` ([osrf/rocker][osrf-rocker]) is OSRF's wrapper
around `docker run` providing `--x11`, `--nvidia`, `--cuda`,
`--devices`, `--user`, `--ssh`, and others. For development
workflows (rapid iteration, mounting host workspace, X11+GPU+USB
in one shot), it materially reduces ceremony. For the runbook,
the right call is probably:
- **Bake** stable runtime config into the Dockerfile/Compose
  (apt deps, ROS install, workspace build).
- **Use** `rocker` (or Compose with the same flags) for the
  dev-loop launch ceremony (X11 socket, /dev/dri, /dev/ttyDXL,
  workspace bind-mount).

Decision deferred to the architecture-design phase.

## Area 3 — rmw_zenoh_cpp configuration and cross-container discovery

### Installation

- Apt: `sudo apt install ros-lyrical-rmw-zenoh-cpp` on Resolute
  (verified in `Packages.gz`).
- Source: `git clone https://github.com/ros2/rmw_zenoh.git -b lyrical`
  then `colcon build`. The `lyrical` branch exists alongside
  `humble`, `jazzy`, `kilted`, `rolling`. ([rmw_zenoh branches][rmw-zenoh-branches])

### Configuration env vars (all confirmed in the `lyrical` README)

| Env var | Effect |
|---|---|
| `RMW_IMPLEMENTATION=rmw_zenoh_cpp` | Selects this RMW |
| `ZENOH_ROUTER_CONFIG_URI` | Absolute path to custom router json5 |
| `ZENOH_SESSION_CONFIG_URI` | Absolute path to custom session json5 |
| `ZENOH_CONFIG_OVERRIDE` | `key=value` override syntax |
| `ZENOH_ROUTER_CHECK_ATTEMPTS=-1` | Skip router wait (enables peer-to-peer) |

Default config files ship at
`rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_{ROUTER,SESSION}_CONFIG.json5`
in the installed package tree.

### Router vs peer mode

The README states: "Without the Zenoh router, nodes will not be
able to discover each other since multicast discovery is disabled
by default in the node's session config." Default deployment runs
a `rmw_zenohd` router process; peer-to-peer is possible but
requires explicit config override
(`scouting/multicast/enabled=true` + `ZENOH_ROUTER_CHECK_ATTEMPTS=-1`).
([rmw_zenoh README][rmw-zenoh-readme])

### Cross-container ports and discovery

- Default session connects to `tcp/localhost:7447` (each container
  looks for a router on its own loopback — out-of-the-box, two
  sibling containers do NOT discover each other).
- Default router binds `tcp/[::]:7447` (all interfaces).
- UDP `224.0.0.224:7446` is the multicast scout address, **disabled
  by default** in both configs.
- Recommended cross-container pattern: dedicated router container
  on a user-defined bridge network; controller and rviz containers
  override `connect.endpoints` to `tcp/<router-container-name>:7447`.
- No `--network=host` required.

This sidesteps the multicast-across-netns problem DDS has —
Docker bridge networking just works for Zenoh.

### What's NOT needed in this architecture

- **`zenoh-bridge-ros2dds`**: scope is "bridge DDS-RMW projects to
  Zenoh consumers." Moot when ROS 2 itself uses `rmw_zenoh_cpp`.
- **`zenohd` debian package**: not in Ubuntu archives. The router
  binary ships inside `ros-lyrical-rmw-zenoh-cpp` as
  `rmw_zenohd`, or from upstream Eclipse Zenoh releases.

### Flag — zenoh-dart does not exist

The `eclipse-zenoh` GitHub org has 29 repos; Dart/Flutter
bindings are **not** among them. The original CLAUDE.md plan for
a Phase-7-equivalent Flutter client subscribing to Zenoh
keyexpressions assumes `zenoh-dart` exists. It does not.

Realistic paths:
1. **`zenoh-pico` + Dart FFI** — `zenoh-pico` is a C99 Zenoh
   client (Eclipse, official); Dart's FFI mechanism can call into
   it. Most work moves into Dart wrapping.
2. **Community Dart binding** — search outside the org; if a
   community binding exists, vet license + maintenance health.
3. **HTTP/WS bridge** — Zenoh can expose REST/WebSocket; Flutter
   client uses that instead of native Zenoh transport.

Decision deferred to the Phase-7-equivalent design step. **No
blocker for the controller-side architecture.**

## Area 4 — USB pass-through to Docker (FT232H / Dynamixel)

### Symlink resolution

Docker 1.11.0 (2016) added symlink resolution to `--device`. So
`--device=/dev/ttyDXL` passes through the resolved target
(`/dev/ttyUSB0`); the symlink name itself does not appear inside
the container. ([docker release notes][docker-1.11-release-notes])

Trossen's `xs_sdk` hard-codes `PORT=/dev/ttyDXL` and
`BAUDRATE=1000000` in `xs_sdk_obj.h:22`. Options inside the
container:

1. **Recreate the symlink at container start** via an entrypoint
   script: `ln -sf /dev/ttyUSB0 /dev/ttyDXL`. Simplest.
2. **Patch `xs_sdk`** to take the port from a ROS parameter.
   Cleaner but a Trossen-source patch.
3. **Pass both** with `--device=/dev/ttyDXL:/dev/ttyDXL`. The
   left side is the host path (resolved); the right side is the
   in-container path. This makes the in-container node appear at
   `/dev/ttyDXL`, but it's still backed by the FTDI device.
   **This is the cleanest solution and matches Trossen's
   hardcoded expectation.** (Unverified that Docker creates the
   symlink-name device node at the in-container path; needs a
   smoke test.)

### udev rules on the host

udev runs only on the host. Trossen's `99-interbotix-udev.rules`
must be installed in `/etc/udev/rules.d/` on the **host**
(matches the QEMU runbook's Phase-4 approach). The rule:
- Sets `SYMLINK+="ttyDXL"` — creates the symlink on host.
- Sets `ATTR{latency_timer}="1"` — writes host sysfs.
- Sets `MODE="0666"` — propagates to container via inode
  permissions.

The container does NOT need (and cannot enforce) udev rules
itself. The image build does NOT need to install the rules file.

### Hot-plug fragility

Devices assigned via `--device` are static at create-time. If the
U2D2 disconnects:
- In-container fd returns I/O errors (`-ENODEV`).
- On replug, the kernel may allocate a new minor (`ttyUSB1`); the
  container's allow-list still references the old minor.

`--device-cgroup-rule='c 188:* rmw'` permits a major:minor class
to handle replug. (Major 188 is the standard usb-serial char
device major; verify on Resolute.)

### Latency timer

The `latency_timer=1` setting is in sysfs, not the device node.
The host-side udev rule sets it once when the device binds. It
persists for the lifetime of the device binding. **No additional
work needed inside the container.**

## Area 5 — Containerized rviz on hybrid graphics

### Display server defaults

Ubuntu 26.04 release notes: "The Ubuntu Desktop session now runs
only on the Wayland back end, because GNOME Shell can no longer
run as an X.org session." XWayland (package `xwayland`
2:24.1.10-1) provides X11 compat.
([Ubuntu 26.04 release notes][ubuntu-2604-rel])

### rviz2 on Wayland

rviz2 does **not** support Wayland natively. PR
`ros2/rviz#1253` (merged 2024-07-26, backported to Jazzy) makes
rviz2 auto-detect Wayland and force `QT_QPA_PLATFORM=xcb`,
routing through XWayland. Lyrical inherits this.
([ros2/rviz#1253][rviz-pr-1253])

Implication: even on a Wayland host, the rviz container still
needs `/tmp/.X11-unix` bind-mounted for the XWayland socket.

### X11 forwarding pattern

```
docker run \
  --device=/dev/dri/renderD128 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY=$DISPLAY \
  --user $(id -u):$(id -g) \
  --ipc=host \
  <image>
```

Plus an X access control concession:
- `xhost +local:` — broad, simplest, scriptable.
- `xhost +si:localuser:$USER` — granular, X-org-documented
  ([Xsecurity man page][xsecurity]).

With `--user $(id -u):$(id -g)` matching the host user, the
`localuser` ACL pattern works without any X access leak.

### GPU access from container

- `--device=/dev/dri/renderD128` (iGPU) sufficient for rviz; Mesa
  picks Iris Xe automatically.
- `--device=/dev/dri/renderD129` (dGPU) only if CUDA/NVENC
  workloads added later.
- Mesa env: `DRI_PRIME=1` or `DRI_PRIME=pci-0000_XX_00_0` to
  force one of multiple exposed nodes
  ([Mesa env vars][mesa-envvars]).
- Container must include `libgl1-mesa-dri` and `libglx-mesa0`.
- Container user must be in the `render` group (GID-matched to
  host). The `osrf/ros:lyrical-desktop-resolute` base may or may
  not include this — verify on first build.

### NVIDIA Container Toolkit — when is it needed?

Only when the container needs the proprietary NVIDIA driver stack:
- CUDA compute (Isaac ROS, ML inference).
- NVENC/NVDEC video encoding.
- NVIDIA-OpenGL (display capability).

For rviz-on-iGPU, **not needed**. The Mesa + `/dev/dri/renderD128`
path is independent of the NVIDIA driver entirely.
([NVIDIA install guide][nvidia-toolkit])

### Hybrid-graphics specifics for this laptop

PRIME render-offload variables (`__GLX_VENDOR_LIBRARY_NAME=nvidia`,
`__NV_PRIME_RENDER_OFFLOAD=1`) only matter for containers with
NVIDIA's GLX provider injected (via Container Toolkit). For a
Mesa-only iGPU container, they're inert.

The Humble project verified the iGPU path inside a QEMU guest
(virgl3D backed by host iGPU). The Docker path is parallel:
expose `/dev/dri/renderD128`, ship Mesa userspace, expect Iris
Xe rendering. **Not yet verified for Lyrical** — first runbook
verification step.

### `rocker` for the dev loop

`osrf/rocker` ([osrf/rocker][osrf-rocker]) extensions relevant
here:
- `--x11`: X11 socket bind + ACL.
- `--devices /dev/dri /dev/ttyDXL`: device list.
- `--user`: UID/GID match.
- `--volume`: workspace bind-mount.

One command runs the dev container with all the ceremony.
Probably the right answer for the development loop; production-
style `docker compose` files can encode the same flags for
repeatability.

## Architectural implications

### Settled by this research

1. **No DDS layer.** rmw_zenoh_cpp from inception. No
   `zenoh-bridge-ros2dds`. No multicast discovery.
2. **Bridge network, not host network.** A user-defined Docker
   bridge with a dedicated router container is the default
   architecture. `--network=host` available as escape hatch but
   not default.
3. **Bare-metal Resolute host.** The host runs:
   - Docker engine.
   - Trossen udev rules in `/etc/udev/rules.d/`.
   - Optionally `rocker` for the dev loop.
   - No host-side ROS 2 install (decision: rviz in container too).
4. **Three-container minimal topology**:
   ```
   ┌─────────────────────────────┐
   │ rmw_zenohd router           │   tcp 7447
   └──────────────┬──────────────┘
                  │
   ┌──────────────┴──────────────┐
   │ controller (xs_sdk)         │   --device=/dev/ttyDXL
   └─────────────────────────────┘
   ┌──────────────────────────────┐
   │ rviz2                       │   --device=/dev/dri/renderD128
   │                             │   X11 socket + Wayland XWayland
   └─────────────────────────────┘
   ```
5. **Image base** (revised 2026-05-23 after empirical verification):
   single `osrf/ros:lyrical-desktop-full-resolute` for all three
   containers. The earlier draft of this section proposed a two-image
   split (`osrf/ros:lyrical-desktop-resolute` for rviz +
   `osrf/ros:lyrical-ros-base-resolute` for the controller) but
   `osrf/ros:lyrical-ros-base-resolute` does not exist — the
   `ros-base` variants live on `library/ros` (pull as
   `ros:lyrical-ros-base-resolute`), not on `osrf/ros`. The single
   `desktop-full` image avoids that namespace cross-up and simplifies
   operations at a ~2 GB per-image cost.
6. **Trossen installer requires patching** for Lyrical:
   - Distro/version validation arrays.
   - PEP 668 venv pattern for Python deps.
   - Strip `sudo` (or keep for host-style installs).
   - udev install becomes host-side only.

### Open and needing follow-up

1. **Container symlink behavior** — does
   `--device=/dev/ttyDXL:/dev/ttyDXL` actually create the
   in-container node at `/dev/ttyDXL` (the symlink name), or does
   Docker resolve both sides? **Smoke test before runbook
   drafting.**
2. **Hot-plug runbook entry** — `--device-cgroup-rule` major
   number for usb-serial on Resolute. Verify the major.
3. **`zenoh-dart` alternative** — `zenoh-pico` + Dart FFI vs
   community binding vs WebSocket bridge. **Defer to
   Phase-7-equivalent design.**
4. **`rocker` vs `docker compose`** for the dev loop.
   `rocker` is more ergonomic for one-shot launches; Compose is
   more reproducible. Likely answer: Compose for the documented
   topology, `rocker` recipes for ad-hoc.
5. **Trossen source pinning** — same question as the Lyrical-Luth
   fork's Phase-3b: pin to a `jazzy` SHA or maintain a `lyrical`
   branch in a Trossen fork. **Defer to architectural design.**
6. **GUI snapshots** — Docker image tagging strategy at phase
   boundaries (replaces qcow2 disk-only snapshots from the QEMU
   runbook). Default plan: tag images with phase number after
   verification.

## Empirical verification (2026-05-23)

Prototype Dockerfile (`docker/Dockerfile`) built and cross-container
Zenoh discovery + message flow tested on this Kubuntu 24.04 Noble
development host (eventual target host is Ubuntu 26.04 Resolute).
Findings folded back into CLAUDE.md and corrections applied to this
document above.

### Image build (BuildKit)

- `docker buildx build -t px100-base:dev --load docker/` succeeded
  in 13.1 s. Image manifest digest
  `sha256:8b0fb4f244dbef6c615ced4f35a6df369ef90221c54230e5572418b5426ce47f`.
  Unique content 1.91 GB.
- The legacy `docker build` builder is deprecated upstream and prints
  a deprecation banner; `docker buildx build --load` is the current
  command. The `--load` flag imports the image into the local Docker
  engine so plain `docker run` can use it.
- The OSRF image's apt sources include
  `packages.ros.org/ros2-testing/ubuntu resolute` in addition to
  Ubuntu's archive. The
  `ros-lyrical-rmw-zenoh-cpp 0.10.4-1resolute.20260430.211235`
  package resolves from the ros2-testing repo, NOT from Ubuntu's
  own archive. Production deployments should re-evaluate when (or if)
  a stable Lyrical ROS apt repo is published.

### Single-container Zenoh smoke test

Inside one container with `RMW_IMPLEMENTATION=rmw_zenoh_cpp`:
`apt install ros-lyrical-rmw-zenoh-cpp` → `ros2 run rmw_zenoh_cpp
rmw_zenohd` in background → `ros2 run demo_nodes_cpp talker` →
`ros2 topic echo --once /chatter` returned `data: 'Hello World: N'`.
End-to-end working. Confirms the image base + apt path + Zenoh
runtime are usable as-is.

### Cross-container Zenoh test (the load-bearing result)

Three containers on user-defined Docker bridge `px100-net`:

```
router      —  px100-base:dev  ros2 run rmw_zenoh_cpp rmw_zenohd
talker      —  px100-base:dev  -e ZENOH_CONFIG_OVERRIDE=...  ros2 run demo_nodes_cpp talker
listener    —  px100-base:dev  -e ZENOH_CONFIG_OVERRIDE=...  ros2 topic echo --once /chatter
```

- **First attempt failed.** With only `connect/endpoints` overridden
  to `tcp/router:7447`, the talker reached the router and was
  gossiped to the listener, but the listener could not connect to
  the talker: the talker had advertised its listen-locator as
  `tcp/[::1]:32949` (IPv6 loopback), which is unreachable across
  Docker bridges. Default session `mode` is `peer`, and the default
  `listen.endpoints` for a peer is loopback-only.
- **Fix: switch session mode to `client`.** Override becomes
  `mode="client";connect/endpoints=["tcp/router:7447"]`. In client
  mode the node opens no listen socket; all comms relay through the
  router. The listener then saw `/talker` in `ros2 node list`,
  `/chatter` in `ros2 topic list`, and successfully echoed
  `data: 'Hello World: 26'`.
- **`ZENOH_CONFIG_OVERRIDE` multi-override syntax confirmed**
  (primary source: `https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md`):
  semicolon-separated `key/path=value` pairs.
- **Asymmetry**: overrides apply to BOTH session config (used by
  ROS nodes) AND router config (used by `rmw_zenohd`). Setting
  `mode="client"` on the router container would break it. The
  router container must run without `ZENOH_CONFIG_OVERRIDE`; only
  the non-router containers carry the override.
- **Multicast NOT involved.** Zenoh's default scouting/multicast is
  disabled in both router and session configs. Discovery is
  router-mediated TCP unicast end-to-end. No Docker
  multicast-across-netns workarounds needed.

### Architectural confirmations and corrections

- **Single image base sticks.** `osrf/ros:lyrical-desktop-full-resolute`
  works for all three containers in the topology. The earlier
  two-image-split idea was both factually wrong (one of the two
  proposed image tags doesn't exist) and unnecessary.
- **Bridge networking sticks.** No `--network=host` is needed.
  Container-DNS resolves the `router` container name to its bridge
  IP (`172.18.0.2/16` in this test).
- **Phase-0 architecture validated end-to-end** for the basic
  pub/sub case. The remaining unknowns concern hardware (USB
  pass-through, X11/Wayland forwarding for rviz, GPU `/dev/dri`
  access) and the Trossen workspace build, which Phase 2 and Phase
  4 will exercise.

## Sources (consolidated)

[docker-run-ref]: https://docs.docker.com/reference/cli/docker/container/run/
[docker-1.11-release-notes]: https://docs.docker.com/engine/release-notes/prior-releases/
[docker-cache]: https://docs.docker.com/build/cache/
[docker-resource-constraints]: https://docs.docker.com/engine/containers/resource_constraints/
[kernel-cgroup-v2]: https://docs.kernel.org/admin-guide/cgroup-v2.html
[packages-ros]: http://packages.ros.org/ros2/ubuntu/dists/resolute/main/binary-amd64/Packages.gz
[osrf-docker-images]: https://github.com/osrf/docker_images
[osrf-ros-tags]: https://hub.docker.com/r/osrf/ros/tags?name=lyrical
[osrf-rocker]: https://github.com/osrf/rocker
[rmw-zenoh-readme]: https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md
[rmw-zenoh-branches]: https://github.com/ros2/rmw_zenoh/branches
[zenoh-router-config]: https://github.com/ros2/rmw_zenoh/blob/lyrical/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5
[eclipse-zenoh-org]: https://github.com/eclipse-zenoh
[mesa-envvars]: https://docs.mesa3d.org/envvars.html
[nvidia-toolkit]: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
[ubuntu-2604-rel]: https://documentation.ubuntu.com/release-notes/26.04/summary-for-lts-users/
[rviz-pr-1253]: https://github.com/ros2/rviz/pull/1253
[xsecurity]: https://www.x.org/releases/current/doc/man/man7/Xsecurity.7.xhtml
