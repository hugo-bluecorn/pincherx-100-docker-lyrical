# pincherx-100-docker-lyrical

A community runbook for operating the Trossen Interbotix **PincherX-100**
on **ROS 2 Lyrical Luth** (May 2026 LTS), fully containerized in
**Docker** on a bare-metal **Ubuntu 26.04 Resolute** host. No VMs, no
DDS — `rmw_zenoh_cpp` from inception.

## Why this fork exists

The PincherX-100 has been [discontinued by
Trossen](https://www.trossenrobotics.com/pincherx100) — the product page
carries the banner *"THIS PRODUCT HAS BEEN DISCONTINUED"*. Trossen's
`xsarm_amd64_install.sh` stops at Humble; they have not ported it to
Iron, Jazzy, or Lyrical, and won't.

For existing PincherX-100 owners who want to keep using the arm on
newer ROS 2 distros, the only path forward is community work. There are
now three sibling repos covering this territory:

| Repo | Architecture | Status |
|---|---|---|
| [pincherx-100-runbook](https://github.com/hugo-bluecorn/pincherx-100-runbook) | ROS 2 Humble, QEMU/KVM guest, Kubuntu 22.04 | Phase 5 done; Phase 6+ paused |
| [pincherx-100-runbook-lyrical-luth](https://github.com/hugo-bluecorn/pincherx-100-runbook-lyrical-luth) | ROS 2 Lyrical Luth, QEMU/KVM guest, Kubuntu 26.04 | Phase 0 reset; dormant |
| **this repo** | ROS 2 Lyrical Luth, **Docker on bare metal**, Ubuntu 26.04 | Phases 1–6 done, hardware-verified; Phase 7 remaining |

This project exists specifically to **avoid VM-based isolation** and the
virtio-gpu workqueue stalls that complicated the Humble runbook's
arm-control timing. The full architectural rationale lives in
[`research/docker-architecture.md`](research/docker-architecture.md),
with every claim cited to a primary upstream source (Docker docs, ROS 2
docs, Eclipse Zenoh, kernel.org, Mesa, NVIDIA, OSRF).

**If you're a new buyer** rather than an existing owner: Trossen
recommends the **ViperX 300 S** (6 DOF, 750 g payload) or
**WidowX 250 S** (6 DOF, 250 g payload) as successors.

## Architecture in one diagram

```
Ubuntu 26.04 Resolute (bare metal)
├── Docker engine
├── Trossen udev rules (/etc/udev/rules.d/99-interbotix-udev.rules)
└── Docker bridge network: px100-net
    │
    ├── robot container (px100-robot:dev, ros-base tier)
    │     ├── rmw_zenohd router (background, started by the image
    │     │     entrypoint; default config; port 7447 published to
    │     │     the host LAN for external Zenoh clients)
    │     ├── xs_sdk via xsarm_control.launch.py (foreground; peer
    │     │     mode, rmw_zenoh default session config)
    │     └── --device=/dev/ttyDXL  (U2D2 → PincherX-100)
    │
    └── dev container (px100-dev:dev, desktop-full tier)
          ├── rmw_zenohd router (background; federated to the robot
          │     router via ZENOH_CONFIG_OVERRIDE=
          │     'connect/endpoints=["tcp/robot:7447"]', scoped to
          │     the router by the entrypoint)
          ├── rviz2 (foreground; peer mode, default session config)
          └── --device=/dev/dri + /tmp/.X11-unix  (XWayland)
```

**Two containers, one router each** — the rmw_zenoh-canonical "router
per fault domain" pattern proven in Phase 4. Both containers run with
`RMW_IMPLEMENTATION=rmw_zenoh_cpp`; inside each, the router and the
ROS 2 nodes share the container's loopback, so rmw_zenoh's defaults
apply unchanged. The two routers federate via the one-direction
override on the dev side (gossip propagates discovery both ways).
Discovery is TCP unicast (no multicast). No `--network=host` required.

Full per-component justification: [`CLAUDE.md`](CLAUDE.md) and
[`research/docker-architecture.md`](research/docker-architecture.md).

## Status

**Just want a running robot to develop a client against** (no image
build)? See [`runbook/00-quickstart-prebuilt.md`](runbook/00-quickstart-prebuilt.md)
— pull the prebuilt `px100-robot` image from GHCR and run it, with a
hardware-free `--profile sim` mode.

**Phase 6 — pedagogical motion exercise (Babaiasl Labs 3-9 walkthrough)**
is the latest committed phase (`runbook/06-pedagogical-motion-exercise.md`,
2026-05-28), with Lab 3 Code Examples 1 and 2 hardware-verified
end-to-end on the arm.

**Phase 5 — controller container + USB pass-through + arm verification**
was hardware-verified on 2026-05-28: all 5 Dynamixels detected on first
ping attempt, `/px100/joint_states` publishes at ~100 Hz, and a sleep →
home → sleep round-trip via a connect-check script exits 0. Cold-start
warmup baked into the image entrypoint.

All phases:

- **Phase 0** — repo scaffolded; architectural research complete and
  cited.
- **Phase 1** — host preparation (Docker engine, BuildKit, Compose v2).
- **Phase 2** — image build (parameterized Dockerfile, `px100-robot:dev`
  + `px100-dev:dev`).
- **Phase 3** — single-router prototype (superseded by Phase 4).
- **Phase 4** — two-container, two-router federated Zenoh topology
  proven with `urdf_tutorial`.
- **Phase 5** — real-arm bring-up (above).
- **Phase 6** — Babaiasl Labs 3-9 walkthrough (above).
- **Phase 7** — optional Flutter client over LAN. The runbook chapter
  is not yet authored, but the data path it would prove **has shipped
  in the sibling repo
  [pincherx-100-flutter-poc](https://github.com/hugo-bluecorn/pincherx-100-flutter-poc)**:
  a robot-side C++ JSON↔ROS gateway (`px100_zenoh_gateway`, v0.1.0)
  plus a Flutter app (v0.2.0) that drives the arm over Zenoh —
  verified against the real arm from Linux desktop and from an
  Android phone over WiFi (2026-06-03).

The Humble parent at
https://github.com/hugo-bluecorn/pincherx-100-runbook is at Phase 5 done
(Humble + Jammy 22.04 + Noble 24.04 host) and serves as a known-working
fallback if this Docker pivot doesn't pan out.

## Repository layout

```
pincherx-100-docker-lyrical/
├── README.md                you are here
├── CLAUDE.md                project rationale, architecture, constraints
├── LICENSE                  Apache 2.0
├── compose.yaml             Docker Compose topology (robot + dev, two federated routers)
├── compose.consumer.yaml    run a PREBUILT px100-robot image from GHCR (sim/hw profiles)
├── .github/workflows/       CI — publish-robot-image.yml builds + pushes px100-robot to GHCR
├── docker/
│   ├── Dockerfile           parameterized image (BASE_IMAGE selects ros-base vs desktop-full;
│   │                        BUILD_INTERBOTIX=true adds the Interbotix workspace)
│   └── entrypoint.sh        starts rmw_zenohd (bg) + scopes ZENOH_CONFIG_OVERRIDE to the router
├── research/                primary-source research + design analysis — see research/README.md (index)
├── runbook/                 phase-by-phase setup instructions (00 quickstart; Phases 1-6 done)
└── scripts/                 arm-warmup.sh — pre-launch U2D2 cold-start warmup
```

There is no `installers/` directory: the originally-planned "patched
Trossen installer fork" was never needed. The Lyrical patches live as
`lyrical` branches on forks of the three Interbotix repos
(`hugo-bluecorn/interbotix_ros_{core,manipulators,toolboxes}`), which
`docker/Dockerfile` clones and `colcon build`s directly when
`BUILD_INTERBOTIX=true`.

## Conventions

Same as the parent Humble project:

- **Commands** in fenced code blocks; `$` for user, `#` for root, no
  prompt for in-container commands (clarified inline).
- **Why:** boxes explain reasoning behind each step.
- **Verify:** boxes describe expected success indicators.
- **Adapt:** boxes flag values likely to differ per setup.
- **Watch out:** boxes call out known failure modes.
- **Image tags at phase boundaries** replace qcow2 snapshots as the
  rollback mechanism. Tag after each phase's hardware verification:
  `pincherx100-controller:phaseN`, etc.

## For another AI assistant onboarding to this project

The canonical context to read in order is:

1. [`CLAUDE.md`](CLAUDE.md) — what we're building and why
2. [`research/README.md`](research/README.md) — index of the
   primary-source research, starting with
   [`research/docker-architecture.md`](research/docker-architecture.md)

(No `.claude-memory/` pack ships in this repo. A curated seed-memory
pack for the Flutter work lives in the sibling repo's `memory/`
directory instead.)

The architectural research includes the headline surprises that shaped
the design (e.g., `--device` resolves symlinks; rmw_zenoh sidesteps
DDS multicast issues entirely; the 2026-05-23 "`zenoh-dart` does not
exist" flag — since resolved by the community binding
[hugo-bluecorn/zenoh_dart](https://github.com/hugo-bluecorn/zenoh_dart),
proven phone→arm in the sibling Flutter POC). Note the research doc's
own status banner: its topology and image-base recommendations were
superseded by Phase 4's two-container federated pattern.

## License

Licensed under the [Apache License, Version 2.0](LICENSE), matching the
parent Humble and Lyrical-Luth projects. The forked Interbotix repos
that carry the Lyrical patches
(`hugo-bluecorn/interbotix_ros_{core,manipulators,toolboxes}`) retain
their upstream BSD-3-Clause copyright.

## Parent and sibling projects

- Parent (ancestor of the architectural conventions):
  https://github.com/hugo-bluecorn/pincherx-100-runbook
- Sibling (QEMU/KVM-based Lyrical attempt, dormant):
  https://github.com/hugo-bluecorn/pincherx-100-runbook-lyrical-luth
- Sibling (Flutter + Zenoh client; consumes this repo's `px100-robot`
  image; ships the `px100_zenoh_gateway` + the Flutter app):
  https://github.com/hugo-bluecorn/pincherx-100-flutter-poc
