#!/bin/bash
# build.sh <distro> [platform]: build both families locally into the docker
# image store, never pushed:
#   husarion/ros:<distro>-ros-core-local[-<arch>]
#   husarion/ros:<distro>-ros-base-local[-<arch>]
# (no arch suffix for the host's own architecture).
# ros-base is built in the same builder right after ros-core, so its ros-core
# stage is the cached one and its first layers are exactly ros-core's
# (test/run.sh checks it).
# Env: BUILDER (default husarion-ros, a docker-container builder created on
# first use with BUILD_MEMORY, default 12g), BUILD_FLAGS (e.g. --no-cache),
# FASTDDS_DEB_LOCAL (a .deb inside this directory to use instead of the
# release download; its sha256 must match distros.env).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
distro=${1:?usage: build.sh <distro> [platform]}
platform=${2:-linux/$(docker version -f '{{.Server.Arch}}')}
arch=${platform#linux/}
host_arch=$(docker version -f '{{.Server.Arch}}')
suffix=""; [ "$arch" = "$host_arch" ] || suffix="-$arch"
builder=${BUILDER:-husarion-ros}

if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
    docker buildx create --name "$builder" --driver docker-container \
        --driver-opt "memory=${BUILD_MEMORY:-12g}" --driver-opt network=host >/dev/null
fi

mapfile -t args < <("$here/scripts/build-args.sh" "$distro")
if [ -n "${FASTDDS_DEB_LOCAL:-}" ]; then
    args+=(--build-arg "FASTDDS_DEB_LOCAL=${FASTDDS_DEB_LOCAL}")
fi
# shellcheck disable=SC2206
extra=(${BUILD_FLAGS:-})

for target in ros-core ros-base; do
    tag="husarion/ros:${distro}-${target}-local${suffix}"
    echo "== building $tag ($platform)"
    docker buildx build --builder "$builder" --platform "$platform" \
        "${args[@]}" "${extra[@]}" --provenance=false --sbom=false \
        --target "$target" --tag "$tag" --load "$here"
done
