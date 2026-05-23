# 03 — Network and router

Bring up the three-container Zenoh topology via Docker Compose and
verify cross-container ROS 2 messaging. The artefacts that matter here
are `compose.yaml` (in the repo root) and the `px100-base:dev` image
built in Phase 2. No new code, no new images — this phase exercises
the architecture by running it.

This is the load-bearing phase that proves the project's middleware
architecture works end-to-end. If you can run Steps 1-4 below and get
the expected output, the Zenoh + Docker bridge + `rmw_zenoh_cpp`
architecture is empirically validated on your host.

## Goal

After this phase:

- A user-defined Docker bridge network named `px100-net` is created
  by Compose.
- A `router` container is running `ros2 run rmw_zenoh_cpp rmw_zenohd`
  with its default config.
- A `talker` container (the `verify` profile's demo client) is
  publishing `/chatter` via `rmw_zenoh_cpp` in client mode.
- A one-shot `listener` container can subscribe to `/chatter` and
  receive a message.
- `docker compose --profile verify down` removes all of the above
  cleanly with no orphan containers or networks.

## Prerequisites

- Phases 1 and 2 complete.
- `px100-base:dev` image present (verify with `docker images
  px100-base`).

## Sources

- rmw_zenoh README (Lyrical branch) — env vars, config syntax:
  https://github.com/ros2/rmw_zenoh/blob/lyrical/README.md
- rmw_zenoh default session config:
  https://github.com/ros2/rmw_zenoh/blob/lyrical/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5
- rmw_zenoh default router config:
  https://github.com/ros2/rmw_zenoh/blob/lyrical/rmw_zenoh_cpp/config/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5
- Eclipse Zenoh default config reference:
  https://github.com/eclipse-zenoh/zenoh/blob/main/DEFAULT_CONFIG.json5
- Docker Compose v2 spec:
  https://docs.docker.com/reference/compose-file/
- Docker user-defined bridge networking:
  https://docs.docker.com/engine/network/drivers/bridge/

## Architecture (read first)

The topology has three roles on one Docker bridge network:

```
Docker bridge network: px100-net
├── router container:
│     image:    px100-base:dev
│     command:  ros2 run rmw_zenoh_cpp rmw_zenohd
│     env:      (none — uses default router config)
├── talker container (profile: verify):
│     image:    px100-base:dev
│     command:  ros2 run demo_nodes_cpp talker
│     env:      RMW_IMPLEMENTATION=rmw_zenoh_cpp
│               ZENOH_CONFIG_OVERRIDE=mode="client";connect/endpoints=["tcp/router:7447"]
└── listener container (profile: adhoc; one-shot via `docker compose run`):
      image:    px100-base:dev
      command:  <supplied at run time>
      env:      (same as talker)
```

Two non-obvious design choices, captured in
`research/docker-architecture.md` "Empirical verification" section:

1. **`mode="client"`** is required on every non-router container.
   rmw_zenoh defaults to `mode="peer"`, which advertises a
   loopback-only listen-locator that's unreachable across Docker
   network namespaces. The listener discovers the talker via the
   router's gossip but can't connect to it. Client mode makes nodes
   relay everything through the router, sidestepping the locator
   problem.
2. **`ZENOH_CONFIG_OVERRIDE` is NOT set on the router.** The
   override applies to whichever Zenoh config the process loads —
   session for ROS nodes, router for `rmw_zenohd`. Setting
   `mode="client"` on the router would break it. Only non-router
   containers get the override.

## Step 1 — Inspect compose.yaml

```
$ cd ~/<your-project-root>/pincherx-100-docker-lyrical
$ cat compose.yaml
```

> **Why read it first:** Compose is declarative; the file is the
> truth. Familiarize yourself with the YAML anchors
> (`x-px100-base`, `x-zenoh-client-env`) and the profile gates
> before running it.

Key things to notice:

| Section | Effect |
|---|---|
| `name: px100` | Sets the Compose project name (affects container/network defaults). |
| `networks.default.name: px100-net` | Overrides the default network name (otherwise `px100_default`). |
| `x-px100-base: &px100-base` | YAML anchor for shared image/build config (DRY across services). |
| `x-zenoh-client-env: &zenoh-client-env` | YAML anchor for the client-mode Zenoh env block. |
| `services.router` | No profile → always started. No `environment:` override. |
| `services.talker` | `profiles: ["verify"]` → started only when `--profile verify` is passed. |
| `services.listener` | `profiles: ["adhoc"]` → never started by `up`; only via `docker compose run --rm listener ...`. |

> **Adapt:** If you want to change the router's container name (and
> therefore the connect endpoint other containers use), edit both
> `services.router.container_name` AND the `tcp/router:7447` string
> inside `x-zenoh-client-env`. Compose's default DNS resolves
> service names automatically on a user-defined network.

## Step 2 — Build via Compose (cache check)

```
$ docker compose build
```

> **Why use Compose's build instead of `docker buildx build`:** They
> resolve to the same thing — Compose v2 uses BuildKit under the hood
> and pulls the build args from the service's `build:` block. Running
> via Compose ensures the image is tagged exactly as Compose expects
> for the subsequent `up`. Skipping this step works on a fresh repo
> if you've already run Phase 2's standalone build; running it is a
> no-op if the layers are already cached.

> **Verify:** `[+] Building 1/1` followed by `✔ px100-base:dev Built`.
> On a cached build this takes < 2 seconds.

## Step 3 — Bring up the topology

```
$ docker compose --profile verify up -d
$ docker compose ps
```

> **Why `--profile verify`:** Without it, only `services.router` (no
> profile) starts. The `verify` profile additionally starts `talker`
> for the smoke test. Without `-d`, the up runs in the foreground —
> useful for debugging but ties up your shell.

> **Verify:** `docker compose ps` shows `router` and `talker` both in
> `Up` status:
> ```
> NAME      IMAGE            ...   STATUS         PORTS
> router    px100-base:dev   ...   Up N seconds
> talker    px100-base:dev   ...   Up N seconds
> ```

## Step 4 — Verify router and talker

```
$ docker compose logs router | tail -5
$ docker compose logs talker | tail -5
```

> **Verify (router):** Last lines include a Zenoh startup banner:
> ```
> ...zenoh::net::runtime::orchestrator: Zenoh can be reached at: tcp/172.18.0.2:7447
> Started Zenoh router with id <hex-id>
> ```
> The `172.18.0.2` IP is the router container's Docker bridge IP;
> the subnet differs depending on how many bridges Docker has
> created.

> **Verify (talker):** Last lines show the demo talker publishing:
> ```
> [INFO] [...] [talker]: Publishing: 'Hello World: N'
> ```
> The number increments by one per second.

> **Watch out:** If the talker log shows
> `Unable to connect to any locator of scouted peer ...: [tcp/[::1]:NNN]`
> warnings, you missed the `mode="client"` override. The talker is
> in peer mode and advertising a loopback locator. Tear down with
> `docker compose --profile verify down`, double-check compose.yaml
> has the correct `ZENOH_CONFIG_OVERRIDE` block, and bring up again.

## Step 5 — Subscribe via a one-shot listener

```
$ docker compose run --rm listener ros2 topic echo --once /chatter
```

> **Why this proves the architecture:** the listener container is a
> separate process in a separate network namespace from the talker. It
> connects to the router (via the Compose-injected env block),
> receives the talker's gossiped advertisement, and consumes the
> message via the router's relay. If this echoes a `Hello World: N`
> message, **cross-container Zenoh works**.

> **Verify:** Output ends with:
> ```
> data: 'Hello World: N'
> ---
> ```
> for some N.

Other useful one-shot invocations:

```
$ docker compose run --rm listener ros2 node list
$ docker compose run --rm listener ros2 topic list
$ docker compose run --rm listener bash    # interactive shell
```

The `--rm` ensures the container is removed when the command exits.

## Step 6 — Tear down

```
$ docker compose --profile verify down
$ docker ps -a
$ docker network ls | grep px100
```

> **Verify:** `docker ps -a` shows no `router` or `talker` containers.
> `docker network ls` shows no `px100-net` network.

> **Why explicit teardown:** Compose's `down` removes containers AND
> the network it created. Without the `--profile verify`, Compose
> may leave the talker container running (profiles are sticky on
> teardown too). Always teardown with the same profiles you brought
> up.

## Exit criteria

Tick all of:

- [ ] `docker compose --profile verify up -d` creates `px100-net`,
      `router`, `talker`
- [ ] `docker compose logs router` shows the Zenoh startup banner
- [ ] `docker compose logs talker` shows `Publishing: 'Hello World: N'`
- [ ] `docker compose run --rm listener ros2 topic echo --once /chatter`
      echoes one message
- [ ] `docker compose --profile verify down` removes everything cleanly

If all five tick, the Zenoh architecture is empirically validated on
your host. Phase 3 is complete.

## Snapshot point

No new image is built in this phase, so there's nothing new to tag.
The fact that `px100-base:dev` works in this topology is itself the
validation — if you tagged `px100-base:phase2` at the end of Phase 2,
that same tag is still your restore point.

## Next

Future phases:

- **Phase 2b** (deferred): patched Trossen installer + colcon workspace
  baked into the image. Builds on top of `docker/Dockerfile` from
  Phase 2.
- **Phase 4**: controller container + U2D2 USB pass-through (`--device=
  /dev/ttyDXL`). Trossen udev rule installs on the host here (moved
  from Phase 1's CLAUDE.md overview where it was originally listed).
- **Phase 5**: end-to-end connection verification with the arm.
- **Phase 6**: rviz container + X11/Wayland forwarding + `/dev/dri`.
- **Phase 7**: pedagogical motion exercise.
- **Phase 8**: optional Flutter client via Zenoh (needs `zenoh-dart`
  alternative — see CLAUDE.md "Key constraints").
