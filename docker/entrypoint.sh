#!/bin/bash
# Image entrypoint for the px100-robot and px100-dev images.
#
# Sequence:
# 1. Source ROS 2 setup.
# 2. Source Interbotix workspace overlay (robot image only).
# 3. Activate Python venv (robot image only).
# 4. Create /dev/ttyDXL symlink if Docker resolved it away.
# 5. Start rmw_zenohd in the background (inherits ZENOH_CONFIG_OVERRIDE).
# 6. Unset ZENOH_CONFIG_OVERRIDE so the main command uses default session config.
# 7. Install a trap to kill the router on shell exit.
# 8. Sleep briefly so the router binds :7447.
# 9. Run the main command in the foreground.

set -e

source "/opt/ros/${ROS_DISTRO}/setup.bash"

# Interbotix workspace overlay (robot image only; no-op on dev image).
if [ -f /root/interbotix_ws/install/setup.bash ]; then
  source /root/interbotix_ws/install/setup.bash
fi

# Python venv with modern-robotics + transforms3d (robot image only).
if [ -f /root/interbotix_ws/.venv/bin/activate ]; then
  source /root/interbotix_ws/.venv/bin/activate
fi

# USB symlink fallback: Docker --device resolves symlinks, so
# /dev/ttyDXL may arrive as /dev/ttyUSB0. xs_sdk expects /dev/ttyDXL.
if [ -e /dev/ttyUSB0 ] && [ ! -e /dev/ttyDXL ]; then
  ln -sf /dev/ttyUSB0 /dev/ttyDXL
fi

# Cold-start warmup: send one raw Protocol-2.0 PING per motor (1-5)
# via the apt-installed DynamixelSDK Python wrapper. Settles U2D2
# RS-485 direction-switching on the first packets after FTDI
# enumeration; without this, xs_sdk's first ping_motors() can fail
# 0/5 on a freshly-plugged U2D2. No-op if /dev/ttyDXL is absent
# (dev image, or arm not plugged in). Errors silently ignored.
# See project memory project_lyrical_docker_cold_start_quirk.
if [ -e /dev/ttyDXL ]; then
  python3 -c '
from dynamixel_sdk import PortHandler, PacketHandler
p = PortHandler("/dev/ttyDXL")
ph = PacketHandler(2.0)
if p.openPort() and p.setBaudRate(1000000):
    for mid in (1, 2, 3, 4, 5):
        ph.ping(p, mid)
    p.closePort()
' 2>/dev/null || true
fi

# Start the router, inheriting ZENOH_CONFIG_OVERRIDE if set.
ros2 run rmw_zenoh_cpp rmw_zenohd &
ROUTER_PID=$!

cleanup() {
  kill "$ROUTER_PID" 2>/dev/null || true
  wait "$ROUTER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Scope: from here onward, ZENOH_CONFIG_OVERRIDE is not visible to
# the main command.
unset ZENOH_CONFIG_OVERRIDE

# Give the router a moment to bind its listen socket.
sleep 1

"$@"
