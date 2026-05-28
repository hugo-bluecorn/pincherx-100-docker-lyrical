#!/usr/bin/env bash
# arm-warmup.sh — warm the U2D2 RS-485 direction-switching before
# launching the controller stack on a freshly-plugged or freshly-
# powered arm.
#
# Background
# ----------
# `xs_sdk` uses DynamixelWorkbench's `ping(id, log)` call pattern, which
# probes each motor with Protocol 1.0 before Protocol 2.0. On a cold
# U2D2 (just plugged in, or just power-cycled with the arm), the first
# few half-duplex direction switches are unreliable, and the P1.0
# attempts taint the immediately-following P2.0 RX. Result: all 5
# motors fail to answer, xs_sdk FATALs with "Failed to find all
# motors.", and `docker compose up` aborts. See
# `runbook/05-controller-usb-verification.md` watch-outs and project
# memory `project_lyrical_docker_cold_start_quirk`.
#
# A single clean raw Protocol-2.0 PING per motor settles the
# direction-switching. Sending those 5 PINGs once before the next
# `docker compose up` is sufficient warmup.
#
# When to run
# -----------
# * After plugging the U2D2 in fresh.
# * After power-cycling the arm.
# * Any time `xs_sdk` fails to detect all 5 motors.
#
# Not needed
# ----------
# * Within a single arm-on session — `docker compose down` followed by
#   `docker compose up` against a warm arm works without warmup.
#
# Usage
# -----
#     ./scripts/arm-warmup.sh
#
# Then proceed:
#     docker compose up

set -uo pipefail  # no -e: we handle errors explicitly so cleanup always runs

cd "$(dirname "$0")/.."

# --- Pre-flight ---

if [ ! -e /dev/ttyDXL ]; then
    echo "FAIL: /dev/ttyDXL not found on host." >&2
    echo "      Is the U2D2 plugged in? Is the udev rule at" >&2
    echo "      /etc/udev/rules.d/99-interbotix-udev.rules installed?" >&2
    exit 2
fi

if ! docker info >/dev/null 2>&1; then
    echo "FAIL: Docker daemon not reachable." >&2
    exit 2
fi

# --- Warmup ---

echo "[1/4] Tearing down any residual containers..."
docker compose down >/dev/null 2>&1 || true

echo "[2/4] Starting robot container in detached mode..."
if ! docker compose up -d robot >/dev/null; then
    echo "FAIL: docker compose up -d robot exited non-zero." >&2
    exit 2
fi

# Give the entrypoint a moment to start rmw_zenohd and create the
# /dev/ttyDXL symlink inside the container.
sleep 3

echo "[3/4] Sending 5 raw Protocol-2.0 PINGs..."
docker exec robot bash -c '
pip install --quiet pyserial --break-system-packages >/dev/null 2>&1
python3 - <<PY
import serial, time, sys

def crc16_dyn(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc

try:
    s = serial.Serial("/dev/ttyDXL", 1000000, timeout=0.1)
except Exception as exc:
    print(f"FAIL: cannot open /dev/ttyDXL inside container: {exc}", file=sys.stderr)
    sys.exit(3)

ok = 0
for mid in (1, 2, 3, 4, 5):
    body = bytes([0xFF, 0xFF, 0xFD, 0x00, mid, 0x03, 0x00, 0x01])
    crc = crc16_dyn(body)
    s.reset_input_buffer()
    s.write(body + bytes([crc & 0xFF, crc >> 8]))
    time.sleep(0.05)
    resp = s.read(50)
    if len(resp) >= 14:
        ok += 1
        print(f"  ID {mid}: OK ({len(resp)} bytes)")
    else:
        print(f"  ID {mid}: FAIL ({len(resp)} bytes)")
s.close()
sys.exit(0 if ok == 5 else 1)
PY
'
WARMUP=$?

echo "[4/4] Tearing down robot container..."
docker compose down >/dev/null 2>&1 || true

# --- Report ---

echo
case "$WARMUP" in
    0)
        echo "OK — all 5 motors responded. The arm is warm."
        echo "Next: docker compose up"
        exit 0
        ;;
    3)
        echo "FAIL: /dev/ttyDXL not visible inside the container." >&2
        echo "      Possible causes:" >&2
        echo "      - host /dev/ttyDXL is not a symlink to ttyUSB0 (check udev rule)" >&2
        echo "      - --device assignment in compose.yaml is missing or malformed" >&2
        exit 1
        ;;
    *)
        echo "FAIL: one or more motors did not respond." >&2
        echo "      Check the 12 V 3 A barrel-jack PSU and the U2D2 cable." >&2
        echo "      Power-cycle the arm, wait ~10 s, then re-run this script." >&2
        exit 1
        ;;
esac
