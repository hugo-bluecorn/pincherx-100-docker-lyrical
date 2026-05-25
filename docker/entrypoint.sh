#!/bin/bash
# Image entrypoint for the px100-robot and px100-dev images.
#
# Starts rmw_zenohd in the background alongside the main process,
# and scopes ZENOH_CONFIG_OVERRIDE to the router so the main
# process (and any ROS 2 nodes it spawns) loads rmw_zenoh's
# default session config unchanged.
#
# Sequence:
# 1. Source ROS 2 setup (replaces /ros_entrypoint.sh behaviour).
# 2. Start rmw_zenohd in the background, inheriting any
# ZENOH_CONFIG_OVERRIDE env var set on the container (so the
# router's connect.endpoints can be overridden for federation).
# 3. Unset ZENOH_CONFIG_OVERRIDE so the main process sees an
# unmodified env. Without this, the same override would apply
# to the ROS 2 node's session config too.
# 4. Install a trap to kill the router on shell exit.
# 5. Sleep briefly so the router binds :7447 before the main
# process tries to connect.
# 6. Run the main command in the foreground (no exec; the trap
# fires on shell exit).
#
# Container lifetime is tied to the main command. When the main
# command exits, the trap kills the router and the shell exits;
# tini (PID 1, injected by `init: true` in compose) reaps any
# stragglers and the container stops.

set -e

source "/opt/ros/${ROS_DISTRO}/setup.bash"

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

# Give the router a moment to bind its listen socket. rmw_zenoh
# session default ZENOH_ROUTER_CHECK_ATTEMPTS=1 means a single
# retry with a ~1s gap before the session gives up and proceeds
# without a router.
sleep 1

"$@"
