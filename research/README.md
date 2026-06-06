# Research & design analysis — index

Primary-source research and design analysis for the
`pincherx-100-docker-lyrical` project. Every document cites canonical
upstream sources (official docs, project repos/READMEs, source by
`file:line`) — no third-party blogs. See the root
[`CLAUDE.md`](../CLAUDE.md) and [`README.md`](../README.md) for project
context.

## Architecture research (foundational)

- **[docker-architecture.md](docker-architecture.md)** — primary-source
  research synthesis produced before Phase 0 (2026-05-23), justifying
  the foundational decisions (Docker over VM, `rmw_zenoh_cpp` over DDS,
  OSRF image tiers, XWayland for rviz). The headline surprises that
  shaped the design live here. **Note its status banner**: the
  topology and image-base recommendations it settled on (three
  containers, dedicated router, client mode, single image) were
  superseded by Phase 4's two-container, two-router, federated
  pattern; and its "zenoh-dart does not exist" flag has since been
  resolved.

## Python-free Flutter control (analysis chain)

A connected investigation, beyond and independent of the runbook's Phase 7
hello-world subscriber, into letting a future Flutter / Bluecorn app
control the arm by interacting **directly with C++ and/or the ROS 2
graph, avoiding Python**. Read in order:

1. **[ui-to-ros-communication.md](ui-to-ros-communication.md)** —
   conceptual primer: how a UI app in *any* language/framework talks to
   ROS 2 at all. The two strategies (become a ROS participant vs. bridge/
   gateway to a friendly protocol) and the bridge landscape (rosbridge,
   Foxglove, Zenoh, custom gateway). Motivates the gateway choice below.
2. **[interbotix-python-cpp-boundary.md](interbotix-python-cpp-boundary.md)**
   — *what's lost by dropping Python.* Code-level map of the Interbotix
   stack's Python/C++ boundary: the C++ `xs_sdk` exposes a joint-level
   ROS 2 interface (the entire hardware interface); all Cartesian IK/FK
   lives only in Python (`arm.py` via `modern_robotics`). Component +
   package diagrams.
3. **[cpp-kinematics-alternatives.md](cpp-kinematics-alternatives.md)** —
   *how to replace it.* Exhaustive survey of C/C++ (and Dart) alternatives
   to `modern_robotics`, framed by the choice of **where IK runs**: Path A
   (link into the app via Dart FFI) vs Path B (a C++ ROS 2 node the app
   calls over Zenoh). License analysis for commercial use.
4. **[path-b-cartesian-gateway.md](path-b-cartesian-gateway.md)** — *Path B
   expanded* (Path A deferred). Concrete design for a `px100_cartesian_gateway`
   C++ node: what it must replicate from `arm.py`, the kinematics-engine
   choice (B-PoE vs B-KDL), and the Flutter interface (a JSON Zenoh
   queryable — because raw Zenoh clients can't practically call ROS
   services and Dart has no CDR codec). **Still future design** — its
   joint-space-only sibling (no IK) shipped first; see item 5's note.
5. **[poc-flutter-zenoh-control.md](poc-flutter-zenoh-control.md)** — *first
   concrete POC spec.* A simple Flutter + `zenoh-dart` app (no
   rosbridge/foxglove, no gateway): two buttons for home/sleep poses +
   per-joint jog sliders. Direct joint-space commands
   (`JointGroupCommand` / `JointSingleCommand`) over the ROS wire — no
   IK, no singularities. Verified message shapes, joint limits, the
   mandatory Zenoh attachment, and the Dart recipe + verification
   ladder. **Superseded 2026-06-02 — the direct-wire design was
   rejected as Option 1.** The project chose its own Option 2, a thin
   C++ JSON↔ROS gateway, designed and **implemented in the sibling
   [pincherx-100-flutter-poc](https://github.com/hugo-bluecorn/pincherx-100-flutter-poc)
   repo** (`px100_zenoh_gateway` v0.1.0 + Flutter app v0.2.0; verified
   on the real arm and from an Android phone, 2026-06-03; chosen-design
   doc: that repo's `research/poc-zenoh-json-gateway.md`). This doc
   remains the source of the verified message shapes, pose arrays, and
   joint limits the gateway reuses.

## Conventions

- Primary upstream sources only; cite by canonical URL or source `file:line`.
- Mermaid for diagrams (renders inline on GitHub).
- These are analysis/design artifacts, not runbook phases — the
  phase-by-phase setup lives in [`../runbook/`](../runbook/).
