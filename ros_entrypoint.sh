#!/bin/bash
# husarion/ros entrypoint: the ROS 2 environment, then every overlay in
# ROS_OVERLAYS (colon-separated, in order; each a workspace install directory
# holding setup.bash, or a setup.bash itself), then the command.
# A child that needs its own entrypoint calls this one from it.
set -e

source "/opt/ros/$ROS_DISTRO/setup.bash" --

if [ -n "${ROS_OVERLAYS:-}" ]; then
    IFS=: read -r -a _overlays <<< "$ROS_OVERLAYS"
    for _o in "${_overlays[@]}"; do
        [ -n "$_o" ] || continue
        if [ -f "$_o/setup.bash" ]; then
            source "$_o/setup.bash" --
        elif [ -f "$_o" ]; then
            source "$_o" --
        else
            echo "ros_entrypoint.sh: ROS_OVERLAYS entry '$_o' has no setup.bash" >&2
            exit 1
        fi
    done
    unset _overlays _o
fi

exec "$@"
