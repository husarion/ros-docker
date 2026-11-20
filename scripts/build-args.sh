#!/bin/bash
# build-args.sh <distro>: the docker build arguments for <distro> from
# distros.env, one "--build-arg K=V" pair per line (feed it to xargs or read
# it into an array). Also usable as `build-args.sh <distro> get <KEY>` to print
# one value of that distro's block (e.g. ROS_CORE).
#   ROS_CORE_IMAGE_OVERRIDE=<ref>  build FROM that copy of the official
#     ros-core instead (CI: its job-local mirror of the pinned digest). The
#     labels still name the official image and digest.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
distro=${1:?usage: build-args.sh <distro> [get KEY]}
case "$distro" in jazzy|humble|lyrical) ;; *) echo "unknown distro: $distro" >&2; exit 2 ;; esac
D=${distro^^}

val() {
    local k=$1 v
    v=$(sed -n "s/^${k}=//p" "$here/distros.env")
    [ -n "$v" ] || { echo "distros.env has no ${k}" >&2; exit 1; }
    printf '%s' "$v"
}

if [ "${2:-}" = get ]; then
    case "$3" in
        FASTDDS_RELEASE|FASTDDS_SUFFIX|ROS_SNAPSHOT_KEY_FPR) val "$3" ;;
        *) val "${D}_$3" ;;
    esac
    echo
    exit 0
fi

core=$(val "${D}_ROS_CORE")
digest=${core##*@}
image=$core
if [ -n "${ROS_CORE_IMAGE_OVERRIDE:-}" ]; then
    image=$ROS_CORE_IMAGE_OVERRIDE
fi
revision=$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$here" status --porcelain 2>/dev/null)" ]; then revision="${revision}-dirty"; fi

arg() { printf -- '--build-arg\n%s=%s\n' "$1" "$2"; }
arg ROS_CORE_IMAGE "$image"
arg ROS_CORE_NAME "${core%%@*}"
arg ROS_CORE_DIGEST "$digest"
arg DISTRO "$distro"
arg CODENAME "$(val "${D}_CODENAME")"
arg ROS_SNAPSHOT "$(val "${D}_ROS_SNAPSHOT")"
arg UBUNTU_SNAPSHOT "$(val "${D}_UBUNTU_SNAPSHOT")"
arg ROS_SNAPSHOT_KEY_FPR "$(val ROS_SNAPSHOT_KEY_FPR)"
arg FASTDDS_RELEASE "$(val FASTDDS_RELEASE)"
arg FASTDDS_SUFFIX "$(val FASTDDS_SUFFIX)"
arg FASTDDS_PKG "$(val "${D}_FASTDDS_PKG")"
arg FASTDDS_UPSTREAM "$(val "${D}_FASTDDS_UPSTREAM")"
arg FASTDDS_SHA256_amd64 "$(val "${D}_FASTDDS_SHA256_amd64")"
arg FASTDDS_SHA256_arm64 "$(val "${D}_FASTDDS_SHA256_arm64")"
arg ROS_BASE_VERSION "$(val "${D}_ROS_BASE_VERSION")"
arg REVISION "$revision"
