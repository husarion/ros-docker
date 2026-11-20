# husarion/ros: the official ROS 2 images plus what every Husarion ROS image
# shares (README.md). Two targets, two tag families:
#   ros-core  FROM the official ros:<distro>-ros-core, pinned by digest
#   ros-base  FROM our ros-core, plus exactly what the official ros-base adds
# Every value comes from distros.env through scripts/build-args.sh; a build
# without them fails on purpose (the ARGs below have no defaults).

ARG ROS_CORE_IMAGE
# The image the ros-base target is built FROM: the ros-core stage of the same
# build by default. CI passes the ros-core digest it has just pushed, so the
# ros-base layers sit on exactly the bytes published as ros-core.
ARG ROS_CORE_REF=ros-core

FROM ${ROS_CORE_IMAGE} AS ros-core
# The distro distros.env meant; the script checks it is the image's ROS_DISTRO.
ARG DISTRO
ARG CODENAME
ARG ROS_SNAPSHOT
ARG UBUNTU_SNAPSHOT
ARG ROS_SNAPSHOT_KEY_FPR
ARG FASTDDS_RELEASE
ARG FASTDDS_PKG
ARG FASTDDS_UPSTREAM
ARG FASTDDS_SUFFIX
ARG FASTDDS_SHA256_amd64
ARG FASTDDS_SHA256_arm64
# A local file instead of the release download (a fastdds-patched build not
# released yet); its sha256 must still match the pin. Path in the build context.
ARG FASTDDS_DEB_LOCAL=
ARG TARGETARCH

# All of our additions in one layer, in this order (scripts/setup-ros-core.sh):
# snapshot sources, the patched Fast DDS held and pinned, one apt-get upgrade,
# the three RMWs, apt retries, husarion-base-check, the entrypoint.
RUN --mount=type=bind,target=/src \
    DISTRO="${DISTRO}" CODENAME="${CODENAME}" \
    ROS_SNAPSHOT="${ROS_SNAPSHOT}" UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
    ROS_SNAPSHOT_KEY_FPR="${ROS_SNAPSHOT_KEY_FPR}" \
    FASTDDS_RELEASE="${FASTDDS_RELEASE}" FASTDDS_PKG="${FASTDDS_PKG}" \
    FASTDDS_UPSTREAM="${FASTDDS_UPSTREAM}" FASTDDS_SUFFIX="${FASTDDS_SUFFIX}" \
    FASTDDS_SHA256_amd64="${FASTDDS_SHA256_amd64}" FASTDDS_SHA256_arm64="${FASTDDS_SHA256_arm64}" \
    FASTDDS_DEB_LOCAL="${FASTDDS_DEB_LOCAL}" TARGETARCH="${TARGETARCH}" \
    bash /src/scripts/setup-ros-core.sh

ENTRYPOINT ["/ros_entrypoint.sh"]
CMD ["bash"]

ARG ROS_CORE_NAME
ARG ROS_CORE_DIGEST
ARG REVISION=unknown
ARG FASTDDS_UPSTREAM
ARG FASTDDS_SUFFIX
LABEL org.opencontainers.image.title="husarion/ros ${ROS_DISTRO} ros-core" \
      org.opencontainers.image.source="https://github.com/husarion/ros-docker" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.base.name="${ROS_CORE_NAME}" \
      org.opencontainers.image.base.digest="${ROS_CORE_DIGEST}" \
      com.husarion.ros.distro="${ROS_DISTRO}" \
      com.husarion.ros.fastdds="${FASTDDS_UPSTREAM}${FASTDDS_SUFFIX}" \
      com.husarion.ros.fastdds-release="husarion/fastdds-patched ${FASTDDS_RELEASE}" \
      com.husarion.ros.snapshot.ros="${ROS_SNAPSHOT}" \
      com.husarion.ros.snapshot.ubuntu="${UBUNTU_SNAPSHOT}"


FROM ${ROS_CORE_REF} AS ros-base
ARG ROS_BASE_VERSION
# The official ros-base recipe (osrf/docker_images ros/<distro>/ubuntu/<codename>/
# ros-base/Dockerfile), step for step: the bootstrap tools, rosdep, colcon
# mixin and metadata, then ros-<distro>-ros-base. Only the apt-get update lines
# differ: they resolve against the snapshot the ros-core layer pinned.
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
    ros-${ROS_DISTRO}-ros-base=${ROS_BASE_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# What every child does as its last RUN.
RUN husarion-base-check

LABEL org.opencontainers.image.title="husarion/ros ${ROS_DISTRO} ros-base"
