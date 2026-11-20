#!/bin/bash
# sizes.sh <distro> [platform]: compressed (registry, gzip) and uncompressed
# sizes of the local build against the official images at the pinned digests.
# The local images are pushed to a throwaway registry on 127.0.0.1:5555 to get
# their compressed layer sizes; it is removed at the end.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
distro=${1:?usage: sizes.sh <distro> [platform]}
host_arch=$(docker version -f '{{.Server.Arch}}')
platform=${2:-linux/$host_arch}
arch=${platform#linux/}
suffix=""; [ "$arch" = "$host_arch" ] || suffix="-$arch"
get() { "$here/scripts/build-args.sh" "$distro" get "$1"; }
reg=127.0.0.1:5555
name=husarion-ros-sizes-registry
docker run -d --rm --name "$name" -p "$reg:5000" registry:2 >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1' EXIT
sleep 2

mb() { awk -v b="$1" 'BEGIN { printf "%.0f", b / 1000000 }'; }
accept='application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
local_compressed() { # local image -> sum of compressed layer sizes, and the per-layer list
    local t="$reg/sizes/${1##*:}"
    docker tag "$1" "$t" && docker push -q "$t" >/dev/null
    curl -s -H "Accept: $accept" "http://$reg/v2/sizes/${1##*:}/manifests/latest" | jq '[.layers[].size] | add'
}
official_compressed() { # official index ref -> compressed size of its $arch manifest
    docker buildx imagetools inspect --raw "$1" \
        | jq -r --arg a "$arch" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' \
        | head -1 | xargs -I{} docker buildx imagetools inspect --raw "${1%%@*}@{}" | jq '[.layers[].size] | add'
}
uncompressed() { docker image inspect -f '{{.Size}}' "$1"; }

printf '%-44s %12s %14s\n' "image ($platform)" "compressed" "uncompressed"
for fam in core base; do
    off=$(get "ROS_$( [ $fam = core ] && echo CORE || echo BASE_OFFICIAL)")
    # One platform per local reference: make sure the local copy is $arch.
    # (docker refuses a second platform under one digest: pull the platform manifest.)
    offl=$off
    if [ "$(docker image inspect -f '{{.Architecture}}' "$off" 2>/dev/null)" != "$arch" ]; then
        m=$(docker buildx imagetools inspect --raw "$off" | jq -r --arg a "$arch" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' | head -1)
        offl="${off%%@*}@${m}"
        docker pull -q "$offl" >/dev/null
    fi
    ours="husarion/ros:${distro}-ros-${fam}-local${suffix}"
    printf '%-44s %9s MB %11s MB\n' "official ros:${distro}-ros-${fam}" "$(mb "$(official_compressed "$off")")" "$(mb "$(uncompressed "$offl")")"
    printf '%-44s %9s MB %11s MB\n' "husarion/ros:${distro}-ros-${fam}" "$(mb "$(local_compressed "$ours")")" "$(mb "$(uncompressed "$ours")")"
done
