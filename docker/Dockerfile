# syntax=docker/dockerfile:1.6
#
# Parameterized image for the PincherX-100 Docker-Lyrical project.
#
# BASE_IMAGE selects the upstream ROS 2 image tier:
#   - ros:lyrical-ros-base-resolute          (robot — headless)
#   - osrf/ros:lyrical-desktop-full-resolute  (dev — rviz + GUI)
#
# The upstream ROS Docker images live under two Docker Hub namespaces:
#   library/ros  — Docker Official Images (ros-core, ros-base, perception)
#   osrf/ros     — OSRF profile (desktop, desktop-full, simulation)
#
# EXTRA_PKGS adds per-role apt packages (space-separated).
# BUILD_INTERBOTIX=true triggers the Interbotix workspace build (robot image only).
#
# Build:
#   docker compose build                     # both images at once

ARG BASE_IMAGE=osrf/ros:lyrical-desktop-full-resolute
FROM ${BASE_IMAGE}

ARG ROS_DISTRO=lyrical
ARG EXTRA_PKGS=""
ARG BUILD_INTERBOTIX=false

RUN apt-get update && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
        ${EXTRA_PKGS} \
 && rm -rf /var/lib/apt/lists/*

ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

# Interbotix workspace build (robot image only).
# Clones from hugo-bluecorn forks at the lyrical branch — all
# jazzy→lyrical patches (C++20, ament_target_dependencies removal,
# ConstSharedPtr callbacks, Qt6, ros2_control API) are in the forks.
RUN if [ "$BUILD_INTERBOTIX" = "true" ]; then \
      apt-get update && apt-get upgrade -y \
      && apt-get install -y --no-install-recommends \
             git python3-full python3-dev python3-pip \
             clang lld lldb clang-format clang-tidy ninja-build cmake \
      && python3 -m venv --system-site-packages /root/interbotix_ws/.venv \
      && . /root/interbotix_ws/.venv/bin/activate \
      && pip install modern-robotics transforms3d \
      && mkdir -p /root/interbotix_ws/src \
      && cd /root/interbotix_ws/src \
      && git clone -b lyrical https://github.com/hugo-bluecorn/interbotix_ros_core.git \
      && git clone -b lyrical https://github.com/hugo-bluecorn/interbotix_ros_manipulators.git \
      && git clone -b lyrical https://github.com/hugo-bluecorn/interbotix_ros_toolboxes.git \
      && rm interbotix_ros_core/interbotix_ros_xseries/COLCON_IGNORE \
      && cd interbotix_ros_core \
      && git submodule update --init --remote interbotix_ros_xseries/dynamixel_workbench_toolbox \
      && git submodule update --init --remote interbotix_ros_xseries/interbotix_xs_driver \
      && cd /root/interbotix_ws \
      && . /opt/ros/${ROS_DISTRO}/setup.sh \
      && (rosdep install --from-paths src --ignore-src -r -y || true) \
      && colcon build --cmake-args -GNinja \
      && rm -rf /var/lib/apt/lists/* log build/*/CMakeFiles \
    ; fi

COPY entrypoint.sh /px100-entrypoint.sh
RUN chmod +x /px100-entrypoint.sh

ENTRYPOINT ["/px100-entrypoint.sh"]
