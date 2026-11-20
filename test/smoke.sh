#!/bin/bash
# Runs inside an image: the patched Fast DDS is held and every RMW is there.
set -euo pipefail
pkg="ros-${ROS_DISTRO}-${FASTDDS_PKG:?}"
apt-mark showhold | grep -qx "$pkg" || { echo "smoke: $pkg is not held"; exit 1; }
ver=$(dpkg-query -W -f='${Version}' "$pkg")
case "$ver" in *+husarion*) ;; *) echo "smoke: $pkg is $ver, not the patched build"; exit 1 ;; esac
for r in rmw_cyclonedds_cpp rmw_fastrtps_cpp rmw_zenoh_cpp; do ros2 pkg prefix "$r" >/dev/null; done
if [ "${FAMILY:-}" = ros-base ]; then colcon --help >/dev/null; rosdep --version >/dev/null; ros2 pkg prefix rclcpp >/dev/null; fi
echo "smoke: ok ($pkg $ver)"
