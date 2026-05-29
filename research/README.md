# Research & design analysis — index

Primary-source research and design analysis for the
`pincherx-100-docker-lyrical` project. Every document cites canonical
upstream sources (official docs, project repos/READMEs, source by
`file:line`) — no third-party blogs. See the root
[`CLAUDE.md`](../CLAUDE.md) and [`README.md`](../README.md) for project
context.

## Architecture research (foundational)

- **[docker-architecture.md](docker-architecture.md)** — primary-source
  research synthesis produced before Phase 0, justifying every
  architectural decision (Docker over VM, `rmw_zenoh_cpp` over DDS, the
  two-container federated Zenoh topology, OSRF image tiers, XWayland for
  rviz). The headline surprises that shaped the design live here.

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
   services and Dart has no CDR codec).

## Conventions

- Primary upstream sources only; cite by canonical URL or source `file:line`.
- Mermaid for diagrams (renders inline on GitHub).
- These are analysis/design artifacts, not runbook phases — the
  phase-by-phase setup lives in [`../runbook/`](../runbook/).
