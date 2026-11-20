#!/bin/bash
# Our additions to the official ros-core image, run once by the Dockerfile's
# ros-core stage with the build context mounted at /src. One RUN, one layer.
# The order is the contract (SPEC-SHARED-ROS-BASE §3.1, §10.1):
#   1. apt sources -> snapshots.ros.org + snapshot.ubuntu.com, keys checked
#   2. the patched Fast DDS: download, sha256, install, hold, apt pin
#   3. apt-get upgrade, once
#   4. the three RMWs
#   5. apt retries
#   6. husarion-base-check and the held-set record it checks against
#   7. /ros_entrypoint.sh
# and then: nothing installed may be newer than (or missing from) the snapshot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

die() { echo "setup-ros-core: $*" >&2; exit 1; }

: "${DISTRO:?}" "${CODENAME:?}" "${ROS_SNAPSHOT:?}" "${UBUNTU_SNAPSHOT:?}"
: "${ROS_SNAPSHOT_KEY_FPR:?}" "${FASTDDS_RELEASE:?}" "${FASTDDS_PKG:?}"
: "${FASTDDS_UPSTREAM:?}" "${FASTDDS_SUFFIX:?}" "${TARGETARCH:?}"
[ "${ROS_DISTRO:-}" = "$DISTRO" ] || die "the base image is ROS_DISTRO=${ROS_DISTRO:-unset}, distros.env says $DISTRO"
. /etc/os-release
[ "$VERSION_CODENAME" = "$CODENAME" ] || die "the base image is Ubuntu $VERSION_CODENAME, distros.env says $CODENAME"
arch=$(dpkg --print-architecture)
[ "$arch" = "$TARGETARCH" ] || die "dpkg architecture $arch is not the target $TARGETARCH"

apt_update() {
    local i
    for i in 1 2 3 4 5; do
        apt-get -o Acquire::Retries=8 update --error-on=any && return 0
        sleep 20
    done
    die "apt-get update failed five times"
}

# 1. Sources. The snapshot key is the file in keys/, accepted only with the
# fingerprint distros.env pins. The Ubuntu archive key is the image's own.
fpr=$(gpg --show-keys --with-colons /src/keys/ros-snapshots.asc | awk -F: '$1 == "fpr" {print $10; exit}')
[ "$fpr" = "$ROS_SNAPSHOT_KEY_FPR" ] || die "keys/ros-snapshots.asc is $fpr, distros.env pins $ROS_SNAPSHOT_KEY_FPR"
install -m 0644 /src/keys/ros-snapshots.asc /usr/share/keyrings/ros-snapshots.asc
# ros2-apt-source owns the live packages.ros.org source; it goes with it, so
# nothing installed can write the live repository back.
if dpkg-query -W ros2-apt-source >/dev/null 2>&1; then
    apt-get purge -y ros2-apt-source
fi
rm -f /etc/apt/sources.list.d/ros2.sources /etc/apt/sources.list.d/ros2.list \
      /etc/apt/sources.list.d/ros2-latest.list /etc/apt/sources.list.d/ubuntu.sources
# jammy keeps Ubuntu in sources.list: leave only a pointer to the file below.
printf '# husarion/ros: apt sources are /etc/apt/sources.list.d/husarion-snapshot.sources\n' > /etc/apt/sources.list
# snapshot.ubuntu.com/ubuntu serves every architecture, ports included.
cat > /etc/apt/sources.list.d/husarion-snapshot.sources <<EOF
# husarion/ros ${DISTRO}: every package resolves against the snapshots the
# base was built on, so a child built weeks later gets the same sync.
Types: deb
URIs: http://snapshots.ros.org/${DISTRO}/${ROS_SNAPSHOT}/ubuntu
Suites: ${CODENAME}
Components: main
Signed-By: /usr/share/keyrings/ros-snapshots.asc

Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports ${CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
# 5 (first, so the rest of this script retries too).
printf 'Acquire::Retries "8";\n' > /etc/apt/apt.conf.d/80-retries
apt_update

# 2. The patched Fast DDS, installed and held before anything upgrades.
pkg="ros-${DISTRO}-${FASTDDS_PKG}"
asset="${FASTDDS_PKG}-${DISTRO}-${arch}.deb"
sumvar="FASTDDS_SHA256_${arch}"
sum="${!sumvar:-}"
[ ${#sum} = 64 ] || die "distros.env pins no sha256 for $asset"
if [ -n "${FASTDDS_DEB_LOCAL:-}" ]; then
    cp "/src/${FASTDDS_DEB_LOCAL}" /tmp/fastdds.deb
else
    curl -fsSL --retry 5 --retry-delay 10 -o /tmp/fastdds.deb \
        "https://github.com/husarion/fastdds-patched/releases/download/${FASTDDS_RELEASE}/${asset}"
fi
echo "${sum}  /tmp/fastdds.deb" | sha256sum -c -
[ "$(dpkg-deb -f /tmp/fastdds.deb Package)" = "$pkg" ] || die "$asset is not $pkg"
fork=$(dpkg-deb -f /tmp/fastdds.deb Version)
case "$fork" in
    "${FASTDDS_UPSTREAM}"-*"${FASTDDS_SUFFIX}") ;;
    *) die "$asset is $fork, distros.env says ${FASTDDS_UPSTREAM}-*${FASTDDS_SUFFIX}" ;;
esac
# The .deb is the snapshot's own stock build plus the suffix: the snapshot must
# carry exactly that build, or the base would mix a Fast DDS of another sync.
stock="${fork%"${FASTDDS_SUFFIX}"}"
apt-cache madison "$pkg" | awk -F'|' '{gsub(/ /, "", $2); print $2}' | grep -qxF "$stock" \
    || die "the ROS snapshot ${ROS_SNAPSHOT} has no $pkg $stock (it has: $(apt-cache madison "$pkg" | awk -F'|' '{gsub(/ /, "", $2); printf "%s ", $2}')); pick the snapshot the .deb was built from"
apt-get install -y --no-install-recommends --allow-downgrades /tmp/fastdds.deb
apt-mark hold "$pkg"
cat > /etc/apt/preferences.d/husarion-fastdds <<EOF
# husarion/ros: the patched Fast DDS (husarion/fastdds-patched ${FASTDDS_RELEASE}).
# Held as well; husarion-base-check fails any image where it was replaced.
Package: ${pkg}
Pin: version ${fork}
Pin-Priority: 1001
EOF
rm -f /tmp/fastdds.deb

# 3. One upgrade, against the snapshot.
apt-get upgrade -y

# 4. The three RMWs.
apt-get install -y --no-install-recommends \
    "ros-${DISTRO}-rmw-cyclonedds-cpp" \
    "ros-${DISTRO}-rmw-fastrtps-cpp" \
    "ros-${DISTRO}-rmw-zenoh-cpp"

# 6. The check and what it checks against.
install -d /usr/share/husarion-ros
dpkg-query -W -f '${Package} ${Version}\n' $(apt-mark showhold) | sort > /usr/share/husarion-ros/held
install -m 0755 /src/husarion-base-check /usr/local/bin/husarion-base-check

# 7. The entrypoint.
install -m 0755 /src/ros_entrypoint.sh /ros_entrypoint.sh

# Nothing may be newer than, or absent from, the snapshot: apt marks such a
# package "local" (no source has its version) or "upgradable" (upgrade held it
# back). The patched Fast DDS is the one expected local package.
bad=$(apt list --installed 2>/dev/null | awk -F/ 'NR > 1 && /\[installed[^]]*(local|upgradable)/ {print}' | grep -v "^${pkg}/" || true)
[ -z "$bad" ] || die "installed packages the snapshot does not carry at that version:
$bad"

husarion-base-check
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /tmp/*
