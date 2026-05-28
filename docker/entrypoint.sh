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
