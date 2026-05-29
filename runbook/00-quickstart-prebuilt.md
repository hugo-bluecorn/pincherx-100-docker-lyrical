# Quickstart — run a prebuilt robot from GHCR (how-to + learning guide)

This guide is for the case where you just want a **running robot to
develop a client against** (e.g. the Flutter app) and do **not** want to
build the Docker images yourself. It is written to be learned from — each
step explains *what* and *why*, then gives the exact command to run.

If you instead want to build the images from source, that is the normal
`docker compose build` path in [`02-image-build.md`](02-image-build.md);
ignore this file.

---

## 0. The mental model (read once)

- A **container image** is a frozen, ready-to-run filesystem (ROS 2 +
  the Interbotix workspace + the Zenoh middleware, already built).
- A **container registry** is "GitHub for images" — a place to push an
  image once and pull it anywhere. We use **GHCR** (GitHub Container
  Registry, `ghcr.io`), which is part of GitHub and free for our use.
- We **build the image once in CI** (a GitHub Actions workflow) and push
  it to GHCR as `ghcr.io/hugo-bluecorn/px100-robot`. Then any machine can
  **pull** it and run the robot in seconds — no 30-minute workspace build.

So there are two halves:
- **Publish** (done once, in the cloud) — Part A.
- **Consume** (on your laptop) — Parts B–D.

```
 GitHub Actions  ──build──▶  GHCR  ──pull──▶  your laptop  ──:7447──▶  phone
 (Part A)                  (image)           (Parts B–D)            (Flutter)
```

---

## Part A — Publish the image (one time, in the cloud)

The workflow lives at `.github/workflows/publish-robot-image.yml`. It is
set to run **manually** (not on every push) because the build is heavy.
It checks out this repo, builds the **robot** image
(`BASE_IMAGE=ros:lyrical-ros-base-resolute`, `BUILD_INTERBOTIX=true`),
and pushes it to GHCR with two tags: the name you choose (e.g. `lyrical`)
and the exact commit SHA.

**Trigger it** — either way works:

- GitHub website: open the repo → **Actions** tab → **"Publish
  px100-robot image"** → **Run workflow** → set the tag → **Run**.
- Or from your terminal (needs the GitHub CLI `gh`, logged in):
  ```
  gh workflow run publish-robot-image.yml -f tag=lyrical
  ```

Watch it: `gh run watch` (or the Actions tab). The build takes a while
(it clones the forks and compiles the workspace). When it finishes
green, the image exists at `ghcr.io/hugo-bluecorn/px100-robot:lyrical`.

> Why manual? The workspace is 26 C++ packages; rebuilding on every doc
> commit would be wasteful. Re-run this workflow only when the image
> contents actually change.

You do **not** need to create any token for the *push* — the workflow
uses the automatic `GITHUB_TOKEN` (that's the `packages: write`
permission near the top of the workflow file).

---

## Part B — Let your laptop pull the image (one time)

By default a GHCR image pushed from this repo is **private**, so your
laptop must authenticate before it can pull. Two options:

### Option 1 (recommended) — log in with a token

1. Create a token: GitHub → **Settings → Developer settings → Personal
   access tokens → Tokens (classic) → Generate new token** with the
   **`read:packages`** scope. Copy it.
2. Log Docker in to GHCR (paste the token when prompted, or via stdin):
   ```
   echo <YOUR_TOKEN> | docker login ghcr.io -u hugo-bluecorn --password-stdin
   ```
   You only do this once per machine; Docker remembers it.

### Option 2 — make the package public (skip auth)

The robot image contains only open, permissively-licensed software, so
you may make it public if you prefer no login: GitHub → your profile →
**Packages → px100-robot → Package settings → Change visibility →
Public**. After that, anyone can `docker pull` it with no token.

> Which to pick? If you're unsure, use Option 1 (private + login) — it's
> the safe default and you can always go public later.

---

## Part C — Run the robot (on your laptop)

Use `compose.consumer.yaml` (it pulls the image; it does not build). Pick
a profile.

### Simulator — no hardware needed (use this for app development)

```
docker compose -f compose.consumer.yaml --profile sim up
```

This runs the `xs_sdk_sim` node: it publishes `/px100/joint_states` and
accepts joint commands **with no U2D2 and no arm**. Perfect for building
and testing the Flutter client. Stop it with Ctrl-C, or in another
terminal: `docker compose -f compose.consumer.yaml --profile sim down`.

### Real arm — needs the hardware

First make sure the host sees the arm: install the Trossen udev rule and
confirm `/dev/ttyDXL` exists (see
[`05-controller-usb-verification.md`](05-controller-usb-verification.md)).
Then:

```
docker compose -f compose.consumer.yaml --profile hw up
```

### Pinning a specific version

To run an exact published tag instead of `lyrical`:

```
PX100_TAG=phase5 docker compose -f compose.consumer.yaml --profile sim up
```

---

## Part D — Verify it's working

In another terminal, look inside the running container and list topics:

```
docker exec -it $(docker ps -qf name=robot) bash -lc "ros2 topic list"
```

You should see `/px100/joint_states`, `/px100/commands/joint_group`,
`/px100/commands/joint_single`, and the services. Watch the state stream:

```
docker exec -it $(docker ps -qf name=robot) bash -lc "ros2 topic echo /px100/joint_states"
```

In **sim**, publishing a command should make the echoed `joint_states`
move to the commanded values. In **hw**, the physical arm moves.

---

## How this fits the Flutter POC dev loop

1. `--profile sim up` here → a robot on `tcp/<laptop-LAN-ip>:7447`, no arm.
2. In `pincherx-100-flutter-poc`, point the app's `zenoh-dart` client at
   `tcp/<laptop-LAN-ip>:7447` and develop against the sim.
3. Capture the message type hashes once: `ros2 topic info -v
   /px100/commands/joint_group` (same hash in sim and on hardware).
4. When the wire path works in sim, switch to `--profile hw up` and
   validate on the real arm.

---

## Troubleshooting

- **Workflow fails with "no space left on device"** — the build ran out
  of runner disk. The workflow already frees ~20 GB up front; if it still
  fails, the workspace may have grown — consider a larger runner.
- **`docker pull` says "denied" / "unauthorized"** — you skipped Part B,
  or the token lacks `read:packages`. Re-run the `docker login` step, or
  make the package public.
- **`--profile hw up` errors with "no such device /dev/ttyDXL"** — the
  host doesn't see the arm. Fix the udev rule / cabling per runbook 05;
  use `--profile sim` meanwhile.
- **Phone can't reach the robot** — confirm the laptop's firewall allows
  inbound TCP 7447 and the phone is on the same LAN; the robot publishes
  `7447` on the host (see `compose.consumer.yaml`).
