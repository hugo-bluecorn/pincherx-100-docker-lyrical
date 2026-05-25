# 02 — Image build

Build the project's base Docker image. Single Dockerfile at
`docker/Dockerfile`, extends OSRF's official ROS 2 Lyrical desktop-full
image, adds `rmw_zenoh_cpp` and sets it as the default RMW. The image
is named `px100-base:dev` and is the FROM target for the
Trossen-workspace layer that comes in Phase 2b (not yet drafted; lands
when the patched installer is written).

## Goal

After this phase:

- Image `px100-base:dev` exists in the local Docker engine, built via
  BuildKit (`docker buildx build --load`).
- The image contains `ros-lyrical-rmw-zenoh-cpp` (verified by
  `docker run --rm px100-base:dev which rmw_zenohd` or similar).
- `RMW_IMPLEMENTATION` is set to `rmw_zenoh_cpp` as a baked-in `ENV`,
  so containers default to Zenoh without any per-run env-var.
- The Dockerfile's `ARG`-based parameterization (ROS distro, Ubuntu
  codename, image variant) is exercised at least once with defaults.

## Prerequisites

- Phase 1 complete (Docker engine + BuildKit + Compose v2 installed).
- ~10 GB free on `/var/lib/docker` partition (the OSRF Lyrical
  desktop-full base extracts to ~5 GB; the project layer adds another
  ~50-100 MB).

## Sources

- OSRF official ROS 2 Docker images repo:
  https://github.com/osrf/docker_images
- OSRF `osrf/ros` Lyrical tags on Docker Hub:
  https://hub.docker.com/r/osrf/ros/tags?name=lyrical
- Official `library/ros` Lyrical tags on Docker Hub:
  https://hub.docker.com/_/ros (filter for `lyrical`)
- rmw_zenoh_cpp (Lyrical branch):
  https://github.com/ros2/rmw_zenoh/tree/lyrical
- Docker BuildKit / buildx reference:
  https://docs.docker.com/build/buildkit/

## Step 1 — Inspect the Dockerfile

```
$ cd ~/<your-project-root>/pincherx-100-docker-lyrical
$ cat docker/Dockerfile
```

> **Why read it first:** the Dockerfile is the canonical declaration of
> what the image contains. Understanding it now makes the build
> output legible later.

Key things to notice:

| Line | What | Why |
|---|---|---|
| `# syntax=docker/dockerfile:1.6` | BuildKit frontend pin | Lets the Dockerfile use modern syntax features without depending on the daemon's default frontend version. |
| `ARG ROS_DISTRO=lyrical` | Parameterized ROS distro | Lets the same Dockerfile build for jazzy/kilted/rolling without editing. |
| `ARG UBUNTU_CODENAME=resolute` | Parameterized Ubuntu codename | Same Dockerfile builds for noble (if you want to backport). |
| `ARG IMAGE_VARIANT=desktop-full` | Parameterized variant | Could be set to `ros-base` (smaller) or `desktop` (lighter than full). |
| `FROM osrf/ros:${ROS_DISTRO}-${IMAGE_VARIANT}-${UBUNTU_CODENAME}` | Composed base image tag | One `FROM` covers all combinations. |
| `RUN apt-get update && apt-get install -y --no-install-recommends ros-${ROS_DISTRO}-rmw-zenoh-cpp && rm -rf /var/lib/apt/lists/*` | Single-RUN apt pattern | Combining update + install + clean into one layer keeps image lean and avoids apt-cache staleness across layers. |
| `ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp` | Default middleware | Containers default to Zenoh without per-run `-e` flags. Overridable at run time. |

> **Adapt:** Phase 4 splits this into two role-specific images: the
> robot container uses `ros:lyrical-ros-base-resolute` (official
> `library/ros` namespace — headless, ~324 MB) and the dev container
> keeps `osrf/ros:lyrical-desktop-full-resolute`. The Dockerfile is
> reparameterized with `BASE_IMAGE` and `EXTRA_PKGS` args; see
> `runbook/04-topology-proof-urdf-tutorial.md` Step 1.

## Step 2 — Build with BuildKit

```
$ docker buildx build -t px100-base:dev --load docker/
```

> **Why each flag:**
> - `buildx build` selects the current canonical builder (the legacy
>   `docker build` is deprecated upstream).
> - `-t px100-base:dev` tags the resulting image so subsequent
>   `docker run` invocations can reference it by name.
> - `--load` imports the built image into the local Docker engine.
>   Without `--load`, buildx builds into its own cache but the image
>   is not visible to plain `docker images` — surprising behaviour
>   the first time you hit it.
> - `docker/` (positional arg) is the build context. The `Dockerfile`
>   inside that directory is the build definition.

> **Verify:** The build output ends with something like:
> ```
> [+] Building 1/1
>  ✔ px100-base:dev  Built
> ```
> First build takes ~30-60s (pulling the OSRF base image takes the
> majority of that time on a fresh host). Subsequent builds with no
> changes finish in ~1-2s using BuildKit's content-addressable layer
> cache.

> **Watch out:** If you see `DEPRECATED: The legacy builder is
> deprecated and will be removed in a future release`, you accidentally
> ran `docker build` instead of `docker buildx build`. Stop, remove
> the legacy-built image (`docker image rm px100-base:dev`), and
> re-run with `buildx`. See `feedback_current_not_deprecated.md`
> in the project memory.

## Step 3 — Verify the image

```
$ docker images px100-base
REPOSITORY   TAG   IMAGE ID       CREATED          SIZE
px100-base   dev   ...            ...              ~2 GB
```

> **Verify:** Image size reports ~1.9-2.1 GB (the OSRF base layers
> plus ~50-100 MB project layer). The exact reported size depends on
> whether Docker counts shared layers; what matters is the image is
> listed.

```
$ docker run --rm px100-base:dev bash -c '
    echo "ROS_DISTRO=$ROS_DISTRO"
    echo "RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION"
    which rmw_zenohd ros2 rviz2
    apt list --installed 2>/dev/null | grep ros-lyrical-rmw-zenoh
  '
```

> **Verify:** Output should show:
> - `ROS_DISTRO=lyrical`
> - `RMW_IMPLEMENTATION=rmw_zenoh_cpp`
> - Three paths under `/opt/ros/lyrical/bin/` for `rmw_zenohd`, `ros2`,
>   `rviz2`. (`rmw_zenohd` may show as part of a `ros2 run rmw_zenoh_cpp
>   rmw_zenohd` invocation rather than as a standalone binary on PATH;
>   if so, that's fine — see Phase 3.)
> - `ros-lyrical-rmw-zenoh-cpp/now 0.10.4-1resolute.<date>` in the apt
>   list output.

## Step 4 — End-to-end Zenoh smoke test (single container)

A self-contained sanity check that ROS 2 + Zenoh work inside the image
before involving multiple containers in Phase 3.

```
$ docker run -it --rm px100-base:dev bash -c '
    set -e
    ros2 run rmw_zenoh_cpp rmw_zenohd > /tmp/router.log 2>&1 &
    ROUTER=$!
    sleep 3
    kill -0 $ROUTER || { echo "router died"; cat /tmp/router.log; exit 1; }
    ros2 run demo_nodes_cpp talker > /tmp/talker.log 2>&1 &
    TALKER=$!
    sleep 3
    echo "=== nodes ==="
    timeout 5 ros2 node list
    echo "=== topics ==="
    timeout 5 ros2 topic list
    echo "=== chatter echo ==="
    timeout 8 ros2 topic echo --once /chatter
    kill $TALKER $ROUTER
    wait 2>/dev/null
  '
```

> **Verify:** Output shows `/talker` in node list, `/chatter` in topic
> list, and one `data: 'Hello World: N'` message echoed.
>
> This proves the image's ROS 2 install, the rmw_zenoh package install,
> and the bundled `demo_nodes_cpp` are all functional — independent of
> any networking decisions.

## Exit criteria

Tick all of:

- [ ] `docker images px100-base` shows the `dev` tag
- [ ] `docker run --rm px100-base:dev which ros2` resolves to
      `/opt/ros/lyrical/bin/ros2`
- [ ] Step 4's smoke test successfully echoes a `Hello World: N`
      message

If all three tick, Phase 2 is complete.

## Snapshot point

Tag the verified image to preserve the working state before Phase 3
(or Phase 2b when it lands):

```
$ docker tag px100-base:dev px100-base:phase2
$ docker images px100-base
```

The `phase2` tag is the project's analogue of qcow2 disk snapshots
from the parent Humble runbook — a known-good restore point.

## Deferred to Phase 2b

The Trossen colcon workspace build is **not** in this phase. The
patched installer fork needs writing first (see CLAUDE.md Phase 2
description and `research/docker-architecture.md` "Trossen installer
behavior in a container" section). When 2b lands, this Dockerfile
gains a `COPY` of the patched installer + a `RUN` that executes it
and `colcon build`s the resulting workspace.

## Next

→ [03 — Network and router](03-network-router.md)
