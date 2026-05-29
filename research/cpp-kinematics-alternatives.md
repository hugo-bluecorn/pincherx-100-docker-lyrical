# C/C++ alternatives to Python `modern_robotics` — kinematics for a 4-DOF px100

Date: 2026-05-29

Companion to [`interbotix-python-cpp-boundary.md`](interbotix-python-cpp-boundary.md).
That analysis found the one capability a Python-free Flutter client loses
is the **Cartesian IK/FK convenience layer**, which lives only in Python
(`arm.py` via the `modern_robotics` pip package). This document surveys
**C/C++ (and Dart-native) alternatives** to that library, to decide how a
Flutter app — built **beyond and independent of this runbook's Phase 7** —
performs inverse + forward kinematics for the 4-DOF PincherX-100 without
Python.

The reference being replaced is the Python `modern_robotics` library
(Lynch & Park, *Modern Robotics*; `NxRLab/ModernRobotics`, MIT). It
provides screw-theory / Product-of-Exponentials kinematics: `FKinSpace`,
`FKinBody`, `IKinSpace`, `IKinBody`, `JacobianSpace`, `JacobianBody`,
`MatrixExp6`, `MatrixLog6`, `Adjoint`, etc. `arm.py` uses `mr.IKinSpace`
(damped-least-squares Newton-Raphson) for all `set_ee_pose_*` /
`set_ee_cartesian_trajectory` calls.

**Constraints driving the evaluation:**
- **Commercial product** (Bluecorn) → license must be permissive
  (MIT/BSD/Apache/MPL-2.0). GPL/LGPL/AGPL flagged explicitly.
- **4-DOF, underactuated** → the px100 cannot reach an arbitrary 6-DOF
  pose. The solver must handle a **non-square Jacobian** (damped least
  squares / Levenberg-Marquardt / optimization), as `modern_robotics`
  does. Pure analytic 6R solvers are the wrong DOF class.
- **Callable from Flutter/Dart** — either compiled into the app via Dart
  FFI, or run as a ROS 2 C++ node the app reaches over Zenoh.
- **Target distro: ROS 2 Lyrical Luth on Ubuntu 26.04 Resolute.**

## TL;DR — the decision is *where IK runs*, not *which library*

| | **Path A — link IK into the Flutter app (FFI)** | **Path B — IK as a C++ ROS 2 node; Flutter calls over Zenoh** |
|---|---|---|
| Python avoided? | yes | yes |
| License exposure | **at link time** — copyleft (LGPL/AGPL) is a real blocker | **behind a process boundary** — LGPL / MoveIt never touch the app |
| Offline on the phone | yes | no — robot/host must be reachable |
| Best candidates | roll-your-own Eigen · relaxed_ik · IKFast | KDL node · TRAC-IK · MoveIt / `InterbotixMoveItInterface` |

**Recommendation:**
- **Path A primary — roll-your-own PoE FK + damped-least-squares IK on
  Eigen** (`-DEIGEN_MPL2_ONLY`), ~200–300 lines, ~1–2 days, MPL-2.0,
  shipped via Flutter `package_ffi` build hooks + `ffigen`. Cleanest IP,
  smallest footprint, offline-capable, and genuinely small because the
  arm is only 4-DOF.
- **Path B primary — a small standalone C++ node using `kdl_parser` +
  Orocos KDL** (`ChainIkSolverPos_LMA`), exposed as a ROS 2
  service/action; add the TRAC-IK plugin if KDL's numerical IK is flaky.
  Lower effort if the robot is always in the loop.

## Cross-cutting findings (these reshape the options)

1. **⚠️ `Le0nX/ModernRoboticsCpp` (533★, the de-facto complete C++ port,
   Eigen-only) has NO LICENSE FILE** → all-rights-reserved under default
   copyright law → **not legally usable in a commercial product**
   (confirmed via GitHub API: `license: null`, `LICENSE` 404). Usable
   only as a *read-only reference oracle*, never copied. The upstream
   Python `NxRLab/ModernRobotics` is MIT, but that license does not
   extend to a third-party re-implementation that omits its own license.
2. **A complete MIT port exists: `nu-jliu/modern-robotics-cpp`** — but
   depends on **Armadillo + BLAS/LAPACK**, heavier to bundle for FFI than
   Eigen.
3. **Orocos KDL is LGPL-2.1, and is *de-vendored* in Lyrical**
   (`orocos_kdl_vendor` / `python_orocos_kdl_vendor` removed; comes from
   the system `liborocos-kdl` instead). LGPL is fine **dynamically
   linked** or **behind a process boundary**; a problem if **static-linked**
   into a shipped app binary.
4. **IKFast's *generated* code is Apache-2.0** even though the generator
   (`ikfast.py`) is LGPL-3+. Self-contained, dependency-free C++,
   microsecond solves. But generating a valid solver for a **4-DOF** arm
   is fiddly (needs a `Translation3D`/position-task IK type + free-joint
   handling, run once offline).
5. **MoveIt and its IK plugins are already released for Lyrical**
   (verified on index.ros.org): `ros-lyrical-moveit` 2.14.1,
   `trac-ik-kinematics-plugin` 2.2.0, `pick-ik`, `kdl-parser` 3.0.1,
   `tf2-kdl` 0.45.7 — all BSD/Apache. (Lyrical is new ~May 2026; confirm
   mirror coverage with `apt-cache policy` in-container.)
6. **The 4-DOF nuance disqualifies several options.** `ik-geo` and other
   closed-form 6R libraries assume 6-DOF kinematic families — wrong class.
   `bio_ik` explicitly documents "best approximate solutions for low-DOF
   arms"; KDL LMA / relaxed_ik / a DLS loop all handle the non-square
   Jacobian.

## Path A — link into the Flutter app via Dart FFI

| Option | Type | 4-DOF fit | License | Deps / FFI | Maint. | Verdict |
|---|---|---|---|---|---|---|
| **Roll-your-own PoE+DLS on Eigen** | numeric (Newton-Raphson / DLS) | ✅ DLS handles non-square J | **MPL-2.0** (Eigen, `-DEIGEN_MPL2_ONLY`) | Eigen header-only; `extern "C"` shim, flat arrays | — | **🥇 cleanest IP, smallest, ~1–2 days** |
| **relaxed_ik_core** | optimization (groove / RangedIK) | ✅ tolerances/under-constrained | **MIT** | Rust → ready C ABI `.so`; excellent FFI | active | 🥈 ready-made FFI; per-robot config + Rust build |
| **IKFast (generated)** | analytic codegen | ⚠️ needs `Translation3D` gen spike | **Apache-2.0** (generated output) | self-contained C++, zero deps; best FFI | generator old | 🥉 fastest; 4-DOF generation fiddly |
| `nu-jliu/modern-robotics-cpp` | MR port (numeric) | ✅ | **MIT** | Armadillo + BLAS/LAPACK (heavy FFI) | 2026-03 | complete MR port, but heavy dep chain |
| `Le0nX/ModernRoboticsCpp` | MR port (numeric) | ✅ | **NONE — all rights reserved** | Eigen | 2024-04, 533★ | ❌ reference oracle only; cannot ship |
| `QuIK` | numeric (3rd-order) | DH-based | **AGPL-3.0** | Eigen 3.4 | active | ❌ network-copyleft; disqualified |
| Pure-Dart on `ml_linalg` | numeric (hand-rolled) | ✅ if you write exp/log maps | **BSD-2** | no native code; `solve`/`inverse` | active | feasible, slower, no reference port; last resort |

### Roll-your-own — functions to port and effort

Port from the **MIT** `NxRLab/ModernRobotics` source (use `Le0nX` only to
cross-check numerics). For px100 FK + IK you need ~9 short functions:
`VecToso3`/`so3ToVec`, `VecTose3`/`se3ToVec`, `MatrixExp3`/`MatrixLog3`,
**`MatrixExp6`/`MatrixLog6`** (the meat, ~25 lines each), `Adjoint`
(+`TransInv`, `RpToTrans`, `TransToRp`), `FKinSpace`, `JacobianSpace`,
`IKinSpace` (or a damped-least-squares variant:
`θ += Jᵀ(JJᵀ+λ²I)⁻¹ Vs`, more robust near singular/unreachable poses),
and `AxisAng3`. The dynamics half of the library is not needed. The px100
screw axes (`Slist`) and home config `M` come from the URDF / Trossen's
published parameters. FFI delivery: `flutter create --template=package_ffi`
(build hooks + `native_toolchain_c`, cross-platform) + `package:ffigen`;
expose flat `double*` buffers so Dart never sees Eigen types; add
`-DEIGEN_MPL2_ONLY` to the build flags to guarantee an MPL-2.0-clean build.

## Path B — C++ ROS 2 node, Flutter calls over Zenoh

License caveats (LGPL KDL, full MoveIt) **disappear** here because the
code runs as a separate process the app talks to over ROS 2 / Zenoh — the
same boundary the rest of this project already uses. All packages below
are apt-available on Lyrical.

| Option | Type | 4-DOF fit | License | Lyrical apt | Weight | Verdict |
|---|---|---|---|---|---|---|
| **`kdl_parser` + Orocos KDL node** | `ChainIkSolverPos_LMA` (LMA/DLS), `_NR_JL` | ✅ LMA = DLS analog of MR | BSD wrapper over **LGPL-2.1** KDL (dynamic-linked / separate process = clean) | ✅ (`kdl-parser` 3.0.1; KDL from system pkg) | light (Eigen only) | **🥇 lightest direct MR analog** |
| **TRAC-IK plugin** | KDL-NR + SQP (NLopt) | best for ≥6-DOF; works on chains | **BSD** (links KDL/LGPL) | ✅ (`trac-ik-kinematics-plugin` 2.2.0) | medium | add if KDL IK is flaky on the 4-DOF arm |
| **pick_ik** | gradient + evolutionary | ✅ custom cost fns | **BSD-3** | ✅ | medium | modern KDL replacement; MoveIt plugin |
| **bio_ik** | memetic (GA + local) | ✅ documents low-DOF best-approx | **BSD** | port exists | medium | best low-DOF semantics; MoveIt-coupled |
| **MoveIt `MoveGroupInterface`** | full planning | ✅ | **BSD-3** (over LGPL KDL) | ✅ (`moveit` 2.14.1) | **heavy** | `computeCartesianPath` = direct `set_ee_cartesian_trajectory` replacement; only if collision-aware planning wanted |
| **`InterbotixMoveItInterface`** | full planning (Interbotix wrapper) | ✅ | **BSD-3** | source build (this repo's workspace) | **heavy** | the Interbotix-blessed C++ path; pulls full MoveIt |

**FK-only, lightest of all:** `robot_state_publisher` (Apache-2.0, already
running) gives end-effector pose as a TF lookup — no IK. `tf2_kdl` (BSD)
+ `kdl_parser` let a plain C++ node do FK math without MoveIt.

## General-purpose C++ libraries (considered, mostly over-scoped)

Surveyed for completeness; none is the best fit for a 4-DOF arm shipped
via FFI, but each is permissive and capable for larger contexts:

| Library | FK/IK | License | Note |
|---|---|---|---|
| **Pinocchio** | FK first-class; IK = hand-rolled CLIK loop | **BSD-2** | best-maintained, `ros-*-pinocchio` apt pkg; you write the IK loop |
| **RBDL** | FK yes; IK "basic" | **zlib** | light, most permissive; IK not its focus |
| **Drake** | excellent optimization IK | **BSD-3** | far too heavy to embed/FFI |
| **DART** | IK framework | **BSD-2** | heavyweight; better as a simulator |
| **Klampt** | FK/IK + dynamics | **BSD-3** | no tagged release since 2017; not ROS-2-packaged |
| **Robotics Library (RL)** | FK/IK + planning | **BSD-2** | dormant since 2018; not recommended |

## License quick-reference

- **Permissive / commercial-safe:** Eigen (MPL-2.0, with `-DEIGEN_MPL2_ONLY`),
  relaxed_ik (MIT), `nu-jliu/modern-robotics-cpp` (MIT), IKFast *generated*
  code (Apache-2.0), TRAC-IK / pick_ik / bio_ik / MoveIt /
  `InterbotixMoveItInterface` / kdl_parser / tf2_kdl / robot_state_publisher
  (BSD/Apache), Pinocchio (BSD-2), RBDL (zlib), Drake/Klampt (BSD-3),
  DART/RL (BSD-2), `ml_linalg` (BSD-2).
- **Copyleft — flag:** Orocos KDL (**LGPL-2.1**, safe only dynamically
  linked / separate process), IKFast *generator* (LGPL-3+, run offline,
  not shipped), `QuIK` (**AGPL-3.0** — disqualified).
- **No license — flag:** `Le0nX/ModernRoboticsCpp` (all rights reserved;
  reference only).

## Sources

Direct C++ ports of Modern Robotics:
- https://github.com/Le0nX/ModernRoboticsCpp (no LICENSE — GitHub API `license: null`)
- https://github.com/nu-jliu/modern-robotics-cpp (MIT; Armadillo)
- https://github.com/NxRLab/ModernRobotics (upstream Python/MATLAB/Wolfram, MIT; no C/C++)

Major C++ kinematics/dynamics libraries:
- https://github.com/stack-of-tasks/pinocchio
- https://github.com/orocos/orocos_kinematics_dynamics — COPYING (LGPL-2.1)
- https://github.com/ros2/orocos_kdl_vendor (de-vendored in Lyrical)
- https://github.com/rbdl/rbdl
- https://github.com/RobotLocomotion/drake
- https://github.com/dartsim/dart
- https://github.com/krishauser/Klampt
- https://github.com/roboticslibrary/rl

Dedicated IK solvers:
- https://bitbucket.org/traclabs/trac_ik ; https://github.com/aprotyas/trac_ik (ROS 2 port)
- https://github.com/rdiankov/openrave — `python/ikfast.py`, `python/ikfast_generator_cpp.py` (generated code = Apache-2.0)
- https://github.com/uwgraphics/relaxed_ik_core — `src/lib.rs` (MIT, C ABI)
- https://github.com/TAMS-Group/bio_ik
- https://github.com/rpiRobotics/ik-geo (6R-only — excluded)

ROS 2 Lyrical / MoveIt availability:
- https://index.ros.org/p/moveit/ (Lyrical 2.14.1, BSD-3)
- https://index.ros.org/p/trac_ik_kinematics_plugin/ (Lyrical 2.2.0)
- https://index.ros.org/p/kdl_parser/ (Lyrical 3.0.1) ; https://index.ros.org/p/tf2_kdl/ (Lyrical 0.45.7) ; https://index.ros.org/p/pick_ik/
- https://docs.ros.org/en/lyrical/Releases/Release-Lyrical-Luth.html
- https://moveit.picknik.ai/main/doc/examples/kinematics_configuration/kinematics_configuration_tutorial.html
- https://docs.trossenrobotics.com/interbotix_xsarms_docs/ros2_packages/moveit_interface_and_api.html

Lightweight / FFI / Dart-native:
- https://github.com/steffanlloyd/quik (AGPL-3.0)
- https://www.mozilla.org/en-US/MPL/2.0/FAQ/ ; https://libeigen.gitlab.io/eigen/docs-3.3/TopicPreprocessorDirectives.html (`EIGEN_MPL2_ONLY`)
- https://pub.dev/packages/ml_linalg (BSD-2) ; https://pub.dev/packages/vector_math (fixed 2/3/4D only)
- https://dart.dev/interop/c-interop ; https://docs.flutter.dev/platform-integration/bind-native-code (`package_ffi`, build hooks, `extern "C"`)
- https://docs.flutter.dev/platform-integration/android/c-interop ; https://docs.flutter.dev/platform-integration/ios/c-interop
