# 01 — Host preparation

Get the host ready to build and run Docker images for the PincherX-100
ROS 2 Lyrical Luth project. Single-purpose phase: install **Docker
engine** + the modern plugin set (**BuildKit**, **Compose v2**), with
the user able to run `docker` commands without `sudo`. No images
pulled yet, no Trossen workspace built yet, no robot involved.

The CLAUDE.md Phase 1 overview also mentions the Trossen udev rule and
`/dev/ttyDXL` verification. Those steps actually require the U2D2 +
arm to be plugged in, so this runbook moves them to **Phase 4
(controller container + USB pass-through)**. Phase 1 here is purely
host-level Docker setup.

## Goal

After this phase:

- Docker Engine (29.x or later) installed via apt (`docker.io`).
- BuildKit plugin (`docker-buildx`) installed.
- Compose v2 plugin (`docker-compose-v2`) installed.
- Current user in the `docker` group, with new membership effective.
- `docker run --rm hello-world` succeeds without `sudo`.
- `docker info` reports `Cgroup Version: 2`, `Cgroup Driver: systemd`,
  storage driver `overlayfs` (newer) or `overlay2` (older).
- `docker buildx version` and `docker compose version` both return
  cleanly.

## Verified target distros

This runbook was empirically verified on **Ubuntu 24.04 Noble** (the
project's dev/prototyping host). The eventual target is **Ubuntu
26.04 Resolute** — package names and command flags are identical
between the two LTS releases. The only behavioural difference is
which dist `sources.list` references; the apt commands below work
verbatim on either.

Tested combinations (2026-05-23):

| Host distro | Docker Engine | buildx | compose-v2 | Status |
|---|---|---|---|---|
| Ubuntu 24.04 Noble | 29.1.3 | 0.30+ | 2.42+ | **Verified end-to-end** |
| Ubuntu 26.04 Resolute | (same packages expected) | (same) | (same) | Pending |

If you re-run this on Resolute and hit a deviation, please file an
issue against the repo with the apt output.

## Sources

- Docker Engine on Ubuntu install guide (canonical):
  https://docs.docker.com/engine/install/ubuntu/
- Ubuntu Noble `docker.io` package metadata:
  https://packages.ubuntu.com/noble/docker.io
- Ubuntu Resolute `docker.io` package metadata:
  https://packages.ubuntu.com/resolute/docker.io
- Docker BuildKit plugin (`buildx`) package:
  https://packages.ubuntu.com/noble/docker-buildx
- Docker Compose v2 plugin package:
  https://packages.ubuntu.com/noble/docker-compose-v2
- Docker cgroup driver reference:
  https://docs.docker.com/engine/containers/runmetrics/

The Docker docs default install path uses **`docker-ce`** from
Docker's upstream apt repo. This runbook deliberately uses Ubuntu's
own **`docker.io`** package per the project's defaults-first
convention — it ships in Ubuntu's universe component, doesn't require
adding a third-party apt source, and Docker 29.x is recent enough for
all of this project's needs. If you require a newer Docker than
Ubuntu ships, follow the upstream install guide instead.

## Step 0 — Pre-flight inventory

> **Why:** Capture the starting state before changing anything, so a
> future re-run can detect drift. Same `inventory before install`
> pattern as the parent Humble runbook.

```
$ which docker docker.io podman 2>&1
$ df -h /var/lib | sed -n 1,2p
$ groups
$ lsb_release -a
```

> **Verify:** `which docker` returns nothing (Docker not yet
> installed). `df -h /var/lib` shows ≥10 GB free (the OSRF Lyrical
> desktop-full image extracts to ~5-6 GB; budget more if you intend to
> pull additional ROS variants). `groups` does NOT yet include
> `docker`.

> **Adapt:** If `podman` is installed, it can coexist with Docker but
> uses the same `/etc/subuid` / `/etc/subgid` ranges — collisions are
> rare on Ubuntu's defaults. Note its presence and move on; no need
> to uninstall.

> **Watch out:** If `which docker` returns a path under `/snap/`, you
> have the Docker snap installed. Remove it before continuing — the
> snap version has known issues with `--device` flag and bind-mounts
> that the apt version doesn't share:
> ```
> $ sudo snap remove docker
> ```

## Step 1 — Install Docker engine

```
$ sudo apt update
$ sudo apt install -y docker.io docker-buildx docker-compose-v2
```

> **Why:** Three packages in one transaction — installing them
> together avoids the `docker info` showing "no plugins" mid-setup.
> `docker.io` is the engine itself; `docker-buildx` is the current
> canonical builder (the legacy `docker build` is deprecated
> upstream — see https://docs.docker.com/go/buildx/);
> `docker-compose-v2` is the current canonical Compose plugin.
>
> The engine install pulls in `containerd`, `runc`, and `pigz` as
> dependencies. The postinst creates the `docker` system group (GID
> typically 129), enables the `docker.service` systemd unit, and
> starts the daemon — no separate `systemctl enable --now docker` is
> needed.

> **Verify:**
> ```
> $ sudo systemctl is-active docker
> active
> $ sudo systemctl is-enabled docker
> enabled
> ```

> **Watch out:** Ubuntu's libvirt and Docker how-tos historically
> recommend `apt install qemu-kvm` and `apt install docker-ce`
> respectively — both are misleading on Noble/Resolute. `qemu-kvm`
> was removed from the Ubuntu archive (use `qemu-system-x86`);
> `docker-ce` is only available from Docker's upstream apt repo and
> requires adding that repo first. Stick with Ubuntu's own
> `docker.io` for this runbook.

## Step 2 — Add your user to the `docker` group

```
$ sudo usermod -aG docker $USER
$ newgrp docker
```

> **Why:** Without `docker` group membership you must `sudo docker
> ...` for every command. The Compose v2 plugin and BuildKit also
> respect group membership — `sudo`ing them changes their effective
> home directory and breaks the buildx state cache.
>
> `newgrp docker` opens a sub-shell where the new group is effective
> *without* requiring a logout/login. The change persists in that
> shell session only — for new terminal sessions, the group is
> already effective.

> **Verify:**
> ```
> $ groups
> ... docker ...
> $ docker version | grep '^ Version'
>  Version:           29.1.3
> ```
> Both lines should succeed without `sudo`.

> **Adapt:** If `newgrp docker` is awkward in your terminal multiplexer
> (e.g., it spawns a sub-shell you have to `exit`), the alternative
> is a full logout/login. On a desktop session, also restart the
> terminal emulator after re-login so it picks up the new group
> membership.

## Step 3 — Smoke-test the engine

```
$ docker run --rm hello-world
```

> **Verify:** Prints the "Hello from Docker!" greeting. The image
> is auto-pulled from Docker Hub on first run.

```
$ docker info | head -25
```

> **Verify:** Among the output:
> - `Server Version: 29.x.x`
> - `Storage Driver: overlayfs` (newer) or `overlay2` (older)
> - `Cgroup Driver: systemd`
> - `Cgroup Version: 2`
> - `Default Runtime: runc`
>
> If `Cgroup Version` is `1`, the host is on the legacy cgroup
> hierarchy. Recent Ubuntu installs default to cgroup v2; you may
> need to adjust kernel cmdline if v1 is forced. Out of scope for
> this runbook.

> **Watch out:** If `docker info` warns `WARNING: bridge-nf-call-iptables
> is disabled`, that's expected on modern hosts using nftables; safe
> to ignore for this project's bridge-network workload. If you see
> `WARNING: No swap limit support`, also safe — the runbook doesn't
> rely on swap accounting.

## Step 4 — Verify BuildKit and Compose v2 plugins

```
$ docker buildx version
$ docker buildx ls
$ docker compose version
```

> **Verify:**
> - `docker buildx version` returns a `v0.x.x` or newer version
>   string.
> - `docker buildx ls` lists at least one builder (typically a
>   `default` builder with the `docker` driver, marked `running`).
> - `docker compose version` returns a `v2.x.x` version string.

> **Why these plugins matter to this project:** Phase 2 (image build)
> uses `docker buildx build --load`. Phase 3 (network + router) uses
> `docker compose --profile verify up`. Both rely on the plugins
> installed in Step 1 — without them the commands fail with "unknown
> subcommand".

## Step 5 — (Optional) Configure Docker daemon defaults

Out of scope for this phase. The default `daemon.json` is fine for
prototyping. If you need to tune daemon log level, log rotation,
storage driver overrides, or registry mirrors, follow
https://docs.docker.com/engine/daemon/ and restart the daemon. The
project's runbook does not depend on any non-default daemon config.

## Exit criteria

Tick all of:

- [ ] `docker version` succeeds as your user (no `sudo`)
- [ ] `docker info` shows cgroup v2, systemd cgroup driver, overlayfs
      or overlay2 storage
- [ ] `docker buildx version` succeeds
- [ ] `docker compose version` succeeds
- [ ] `docker run --rm hello-world` succeeds and prints the greeting

If all five tick, Phase 1 is complete.

## Snapshot point

Docker is now installed and ready. The next phase (Phase 2) pulls the
OSRF Lyrical base image and builds the project's custom image on top.
Before continuing, capture the host state if you intend to compare it
later:

```
$ dpkg -l | grep -E '^ii\s+(docker|containerd|runc|pigz)' > ~/phase1-host-state.txt
$ docker info > ~/phase1-docker-info.txt
```

These files aren't committed — they're for your own bookkeeping.

## Next

→ [02 — Image build](02-image-build.md)
