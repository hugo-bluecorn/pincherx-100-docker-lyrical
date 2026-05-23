# syntax=docker/dockerfile:1.6
#
# Base image for the PincherX-100 Docker-Lyrical project.
#
# Extends the OSRF official ROS 2 Lyrical Luth desktop-full image
# (Ubuntu 26.04 Resolute) with rmw_zenoh_cpp installed and set as the
# default ROS middleware. Used as the base for the router, controller,
# and rviz containers in the project's three-container topology.
#
# Build (BuildKit / `docker buildx`, the current builder; the legacy
# `docker build` path is deprecated upstream):
#   docker buildx build -t px100-base:dev --load docker/
#
# Build with explicit tag overrides (e.g., to pin to a different
# ROS distro for backporting):
#   docker buildx build --build-arg ROS_DISTRO=jazzy \
#                       --build-arg UBUNTU_CODENAME=noble \
#                       --build-arg IMAGE_VARIANT=desktop-full \
#                       -t px100-base:jazzy --load docker/

ARG ROS_DISTRO=lyrical
ARG UBUNTU_CODENAME=resolute
ARG IMAGE_VARIANT=desktop-full

FROM osrf/ros:${ROS_DISTRO}-${IMAGE_VARIANT}-${UBUNTU_CODENAME}

# Re-declare ARGs after FROM so they're visible in the build stage
ARG ROS_DISTRO

# Install rmw_zenoh_cpp from the Ubuntu archive (Resolute ships ROS 2
# Lyrical packages natively in universe). Single RUN to keep the layer
# count down; strip apt lists to slim the image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ros-${ROS_DISTRO}-rmw-zenoh-cpp \
 && rm -rf /var/lib/apt/lists/*

# Default middleware. Override at run time with -e RMW_IMPLEMENTATION=...
# if a different RMW is wanted for a one-off comparison.
ENV RMW_IMPLEMENTATION=rmw_zenoh_cpp

# Inherit /ros_entrypoint.sh and CMD ["bash"] from the OSRF base image.
