# syntax=docker/dockerfile:1.6
#
# Parameterized image for the PincherX-100 Docker-Lyrical project.
#
# BASE_IMAGE selects the upstream ROS 2 image tier:
# - ros:lyrical-ros-base-resolute (robot — headless)
# - osrf/ros:lyrical-desktop-full-resolute (dev — rviz + GUI)
#
# The upstream ROS Docker images live under two Docker Hub namespaces:
# library/ros — Docker Official Images (ros-core, ros-base, perception)
# osrf/ros — OSRF profile (desktop, desktop-full, simulation)
#
# EXTRA_PKGS adds per-role apt packages (space-separated).
#
# Build examples:
# docker compose build # both images at once
#
# # Or individually:
# docker buildx build \
# --build-arg BASE_IMAGE=ros:lyrical-ros-base-resolute \
# --build-arg EXTRA_PKGS=ros-lyrical-urdf-tutorial \
# -t px100-robot:dev --load docker/
#
# docker buildx build \
# --build-arg BASE_IMAGE=osrf/ros:lyrical-desktop-full-resolute \
# --build-arg "EXTRA_PKGS=ros-lyrical-urdf-tutorial ros-lyrical-joint-state-publisher-gui" \
# -t px100-dev:dev --load docker/

ARG BASE_IMAGE=osrf/ros:lyrical-desktop-full-resolute
FROM ${BASE_IMAGE}

ARG ROS_DISTRO=lyrical
ARG EXTRA_PKGS=""

RUN apt-get update \
&& apt-get install -y --no-install-recommends \
ros-${ROS_DISTRO}-rmw-zenoh-cpp \
${EXTRA_PKGS} \
&& rm -rf /var/lib/apt/lists/*
ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

COPY entrypoint.sh /px100-entrypoint.sh
RUN chmod +x /px100-entrypoint.sh

ENTRYPOINT ["/px100-entrypoint.sh"]
