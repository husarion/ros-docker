# husarion/ros: the official ROS 2 images plus what every Husarion ROS image shares.
# All values come from distros.env (see the justfile).

ARG ROS_CORE_IMAGE
FROM ${ROS_CORE_IMAGE} AS ros-core

ARG CODENAME
ARG ROS_SNAPSHOT
ARG UBUNTU_SNAPSHOT
ARG FASTDDS_PKG
ARG FASTDDS_RELEASE
ARG FASTDDS_SHA256_amd64
ARG FASTDDS_SHA256_arm64
ARG TARGETARCH

COPY keys/ros-snapshots.asc /usr/share/keyrings/ros-snapshots.asc

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 1. apt reads ROS and Ubuntu as they were on the snapshot dates, so images built
#    on this base later install the same package versions it carries.
# 2. The patched Fast DDS from husarion/fastdds-patched, checked and held.
# 3. One upgrade, then the three RMWs.
RUN set -eux; \
    apt-get purge -y ros2-apt-source 2>/dev/null || true; \
    rm -f /etc/apt/sources.list.d/*; \
    : > /etc/apt/sources.list; \
    printf '%s\n' \
      "Types: deb" \
      "URIs: http://snapshots.ros.org/${ROS_DISTRO}/${ROS_SNAPSHOT}/ubuntu" \
      "Suites: ${CODENAME}" \
      "Components: main" \
      "Signed-By: /usr/share/keyrings/ros-snapshots.asc" \
      "" \
      "Types: deb" \
      "URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}" \
      "Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-security" \
      "Components: main universe restricted multiverse" \
      "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg" \
      > /etc/apt/sources.list.d/snapshot.sources; \
    printf 'Acquire::Retries "8";\n' > /etc/apt/apt.conf.d/80-retries; \
    pkg="ros-${ROS_DISTRO}-${FASTDDS_PKG}"; \
    sha="FASTDDS_SHA256_${TARGETARCH}"; \
    curl -fsSL --retry 5 -o /tmp/fastdds.deb \
      "https://github.com/husarion/fastdds-patched/releases/download/${FASTDDS_RELEASE}/${FASTDDS_PKG}-${ROS_DISTRO}-${TARGETARCH}.deb"; \
    echo "${!sha}  /tmp/fastdds.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-downgrades /tmp/fastdds.deb; \
    apt-mark hold "$pkg"; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      "ros-${ROS_DISTRO}-rmw-cyclonedds-cpp" \
      "ros-${ROS_DISTRO}-rmw-fastrtps-cpp" \
      "ros-${ROS_DISTRO}-rmw-zenoh-cpp"; \
    rm -rf /var/lib/apt/lists/* /tmp/fastdds.deb

LABEL org.opencontainers.image.source="https://github.com/husarion/ros-docker" \
      org.opencontainers.image.base.name="${ROS_CORE_IMAGE}"

# ros-base: our ros-core plus exactly what the official ros-base adds
# (osrf/docker_images ros/<distro>/.../ros-base/Dockerfile).
FROM ros-core AS ros-base

RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    git \
    python3-colcon-common-extensions \
    python3-colcon-mixin \
    python3-rosdep \
    python3-vcstool \
    && rm -rf /var/lib/apt/lists/*

RUN rosdep init && \
  rosdep update --rosdistro $ROS_DISTRO

RUN colcon mixin add default \
      https://raw.githubusercontent.com/colcon/colcon-mixin-repository/master/index.yaml && \
    colcon mixin update && \
    colcon metadata add default \
      https://raw.githubusercontent.com/colcon/colcon-metadata-repository/master/index.yaml && \
    colcon metadata update

RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-${ROS_DISTRO}-ros-base \
    && rm -rf /var/lib/apt/lists/*
