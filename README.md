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
| **this repo** | ROS 2 Lyrical Luth, **Docker on bare metal**, Ubuntu 26.04 | Phase 5 done; Phase 6 drafted |

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
└── Docker bridge network: pincherx100-net
    ├── rmw_zenohd router container       (port 7447)
    ├── controller container              (--device=/dev/ttyDXL → U2D2 → PincherX-100)
    └── rviz container                    (--device=/dev/dri/renderD128 + X11 socket)
```

All three containers run with `RMW_IMPLEMENTATION=rmw_zenoh_cpp`. The
router mediates discovery via TCP unicast (no multicast). No
`--network=host` required.

Full per-component justification: [`CLAUDE.md`](CLAUDE.md) and
[`research/docker-architecture.md`](research/docker-architecture.md).

## Status

**Just want a running robot to develop a client against** (no image
build)? See [`runbook/00-quickstart-prebuilt.md`](runbook/00-quickstart-prebuilt.md)
— pull the prebuilt `px100-robot` image from GHCR and run it, with a
hardware-free `--profile sim` mode.

**Phase 5 — controller container + USB pass-through + arm verification**
is the latest committed phase. End-to-end hardware-verified on
2026-05-28: all 5 Dynamixels detected on first ping attempt,
`/px100/joint_states` publishes at ~100 Hz, and a sleep → home →
sleep round-trip via a connect-check script exits 0. Cold-start
warmup baked into the image entrypoint.

**Phase 6 — pedagogical motion exercise (Babaiasl Labs 3-9 walkthrough)**
is drafted in `runbook/06-pedagogical-motion-exercise.md` but not yet
hardware-exercised. It commits after at least Lab 3 is run on the arm.

Earlier phases:

- **Phase 0** — repo scaffolded; architectural research complete and
  cited.
- **Phase 1** — host preparation (Docker engine, BuildKit, Compose v2).
- **Phase 2** — image build (parameterized Dockerfile, `px100-robot:dev`
  + `px100-dev:dev`).
- **Phase 3** — single-router prototype (superseded by Phase 4).
- **Phase 4** — two-container, two-router federated Zenoh topology
  proven with `urdf_tutorial`.
- **Phase 5** — real-arm bring-up (above).
- **Phase 6** — drafted (above).
- **Phase 7** — optional Flutter client over LAN (not started).

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
├── compose.yaml             Docker Compose topology (build + run, router + clients)
├── compose.consumer.yaml    run a PREBUILT px100-robot image from GHCR (sim/hw profiles)
├── .github/workflows/       CI — publish-robot-image.yml builds + pushes px100-robot to GHCR
├── docker/
│   └── Dockerfile           single base image (osrf/ros:lyrical-desktop-full-resolute + rmw_zenoh)
├── research/                primary-source research + design analysis — see research/README.md (index)
├── runbook/                 phase-by-phase setup instructions (Phases 1-5 done; Phase 6 drafted)
├── installers/              patched Trossen installer fork (TBD; install currently inlined in Dockerfile)
└── scripts/                 utility scripts (TBD)
```

Directories marked **TBD** will be populated as phases land. The
research doc carries enough detail that someone could build phase work
from it directly while waiting for the runbook to be drafted.

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

A curated `.claude-memory/` subset following the parent runbook's
pattern will land in a follow-up commit. Until then, the canonical
context to read in order is:

1. [`CLAUDE.md`](CLAUDE.md) — what we're building and why
2. [`research/docker-architecture.md`](research/docker-architecture.md) — primary-source research

The architectural research includes the headline surprises that shaped
the design (e.g., `zenoh-dart` does not exist; `--device` resolves
symlinks; rmw_zenoh sidesteps DDS multicast issues entirely).

## License

Licensed under the [Apache License, Version 2.0](LICENSE), matching the
parent Humble and Lyrical-Luth projects. The patched Trossen installer
(once produced in Phase 2) retains its upstream BSD-3-Clause copyright
with a `Modifications:` note.

## Parent and sibling projects

- Parent (ancestor of the architectural conventions):
  https://github.com/hugo-bluecorn/pincherx-100-runbook
- Sibling (QEMU/KVM-based Lyrical attempt, dormant):
  https://github.com/hugo-bluecorn/pincherx-100-runbook-lyrical-luth
