#!/bin/bash
# test/run.sh <distro> [ros-core-ref] [ros-base-ref]
# The image contract, checked against two given images (by default the local
# build: husarion/ros:<distro>-ros-{core,base}-local[-<arch>]). The same
# script runs locally (just test) and in CI against the pushed digests.
# It only talks to the docker CLI (no bind mounts), so DOCKER_HOST may point
# at a remote engine.
# Env:
#   PLATFORM       linux/amd64 | linux/arm64 (default: the engine's own)
#   TEST_BUILDER   buildx builder for the throwaway children (default: default,
#                  the docker driver, which sees local images)
#   TEST_MEMORY    memory cap per container (default 12g)
#   RT_TIMEOUT     seconds a listener gets per RMW (default 60; give qemu more)
#   KEEP_CHILDREN  1 keeps the throwaway child images
# DDS isolation: every container that runs ROS processes has --network none,
# ROS_DOMAIN_ID=88 and a localhost-only discovery range.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
distro=${1:?usage: test/run.sh <distro> [ros-core-ref] [ros-base-ref]}
host_arch=$(docker version -f '{{.Server.Arch}}')
PLATFORM=${PLATFORM:-linux/$host_arch}
arch=${PLATFORM#linux/}
suffix=""; [ "$arch" = "$host_arch" ] || suffix="-$arch"
core=${2:-husarion/ros:${distro}-ros-core-local${suffix}}
base=${3:-husarion/ros:${distro}-ros-base-local${suffix}}
builder=${TEST_BUILDER:-default}
mem=${TEST_MEMORY:-12g}
rt_timeout=${RT_TIMEOUT:-60}
get() { "$here/scripts/build-args.sh" "$distro" get "$1"; }
fpkg="ros-${distro}-$(get FASTDDS_PKG)"
official_base=$(get ROS_BASE_OFFICIAL)
official_core=$(get ROS_CORE)
ros_snapshot=$(get ROS_SNAPSHOT)
if [ "$distro" = humble ]; then
    iso=(-e ROS_DOMAIN_ID=88 -e ROS_LOCALHOST_ONLY=1)
else
    iso=(-e ROS_DOMAIN_ID=88 -e ROS_AUTOMATIC_DISCOVERY_RANGE=LOCALHOST)
fi
tag_sfx="$distro-$arch-$$"
children=()

pass=0; failn=0; results=()
ok()   { pass=$((pass + 1)); results+=("PASS $1"); echo "PASS $1"; }
nok()  { failn=$((failn + 1)); results+=("FAIL $1"); echo "FAIL $1" >&2; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else nok "$name"; fi; }

# docker run with the image's own entrypoint, the script on stdin.
in_img() { local img=$1 net=$2; shift 2; docker run --rm -i --platform "$PLATFORM" --memory "$mem" --network "$net" "${iso[@]}" "$@" "$img" bash -s; }
child() { # child <name> <dockerfile on stdin>: build a throwaway child, print its tag
    local t="husarion-ros-test/${1}:${tag_sfx}"
    if docker buildx build --builder "$builder" --platform "$PLATFORM" --provenance=false \
        --load -q -t "$t" - >/dev/null; then children+=("$t"); echo "$t"; else return 1; fi
}
cleanup() { [ "${KEEP_CHILDREN:-0}" = 1 ] || [ ${#children[@]} = 0 ] || docker rmi -f "${children[@]}" >/dev/null 2>&1; }
trap cleanup EXIT

echo "== husarion/ros $distro on $PLATFORM: core=$core base=$base"
# The local image store keeps one platform per reference: use a local copy
# only when it is of the architecture under test, else pull that platform.
ensure() {
    local a
    a=$(docker image inspect -f '{{.Architecture}}' "$1" 2>/dev/null || true)
    [ "$a" = "$arch" ] && return 0
    docker pull -q --platform "$PLATFORM" "$1" >/dev/null || { echo "cannot get $1 for $PLATFORM" >&2; exit 2; }
    a=$(docker image inspect -f '{{.Architecture}}' "$1")
    [ "$a" = "$arch" ] || { echo "$1 is $a, not $arch" >&2; exit 2; }
}
for img in "$core" "$base"; do ensure "$img"; done

# --- T1/T2/T9: the contents, on both families --------------------------------
for fam in core base; do
    img=$core; [ $fam = base ] && img=$base
    out=$(in_img "$img" none -e FPKG="$fpkg" -e SNAP="$ros_snapshot" <<'EOF' 2>&1
v=$(dpkg-query -W -f '${Version}' "$FPKG") || { echo "no $FPKG"; exit 1; }
case "$v" in *+husarion*) echo "fastdds $v" ;; *) echo "fastdds $v has no +husarion"; exit 1 ;; esac
apt-mark showhold | grep -qx "$FPKG" || { echo "$FPKG not held"; exit 1; }
grep -qx "Pin: version $v" /etc/apt/preferences.d/husarion-fastdds || { echo "no pin on $v"; exit 1; }
apt-cache policy "$FPKG" | grep -q 1001 || { echo "apt-cache policy shows no 1001 pin"; exit 1; }
echo "held+pinned"
for r in cyclonedds_cpp fastrtps_cpp zenoh_cpp; do
    p="ros-${ROS_DISTRO}-rmw-${r//_/-}"
    dpkg-query -W -f '${Status}' "$p" | grep -q "install ok installed" || { echo "$p missing"; exit 1; }
    [ -e "/opt/ros/${ROS_DISTRO}/lib/librmw_${r}.so" ] || { echo "librmw_${r}.so missing"; exit 1; }
done
echo "rmws 3"
[ -z "${RMW_IMPLEMENTATION:-}" ] || { echo "RMW_IMPLEMENTATION is set: $RMW_IMPLEMENTATION"; exit 1; }
grep -qx 'Acquire::Retries "8";' /etc/apt/apt.conf.d/80-retries || { echo "80-retries"; exit 1; }
grep -q "snapshots.ros.org/${ROS_DISTRO}/${SNAP}/ubuntu" /etc/apt/sources.list.d/husarion-snapshot.sources || { echo "no ROS snapshot source"; exit 1; }
n=$(grep -rhE '^(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ | grep -vcE 'snapshots\.ros\.org|snapshot\.ubuntu\.com')
[ "$n" = 0 ] || { echo "$n non-snapshot apt sources"; exit 1; }
[ ! -d /var/lib/apt/lists/partial ] || [ -z "$(ls /var/lib/apt/lists | grep -v -e '^partial$' -e '^lock$')" ] || { echo "apt lists left in the image"; exit 1; }
husarion-base-check || exit 1
EOF
)
    rc=$?
    echo "$out" | sed "s/^/  [$fam] /"
    check "T1 $fam: $fpkg +husarion, held, apt pin 1001" grep -q "held+pinned" <<< "$out"
    check "T2 $fam: rmw cyclonedds, fastrtps, zenoh installed" grep -q "rmws 3" <<< "$out"
    check "T9 $fam: RMW unset, 80-retries, snapshot-only sources, no apt lists, husarion-base-check OK" test "$rc" = 0
done

labels=$(docker image inspect -f '{{json .Config.Labels}}' "$core")
check "T9 core: labels (fastdds, base digest, snapshots, revision)" bash -c '
    l=$1; for k in com.husarion.ros.fastdds org.opencontainers.image.base.digest com.husarion.ros.snapshot.ros com.husarion.ros.snapshot.ubuntu org.opencontainers.image.revision; do
        v=$(jq -r --arg k "$k" ".[\$k] // empty" <<< "$l"); [ -n "$v" ] || { echo "label $k missing" >&2; exit 1; }; echo "  $k=$v"; done
    [ "$(jq -r ".[\"org.opencontainers.image.base.digest\"]" <<< "$l")" = "${2##*@}" ]' _ "$labels" "$official_core"
check "T9 core: entrypoint /ros_entrypoint.sh" test "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$core")" = '["/ros_entrypoint.sh"]'

# --- T6: ros-base sits on ros-core's layers -----------------------------------
cl=$(docker image inspect -f '{{join .RootFS.Layers " "}}' "$core")
bl=$(docker image inspect -f '{{join .RootFS.Layers " "}}' "$base")
case "$bl " in
    "$cl "*) ok "T6 ros-base diff_ids start with ros-core's ($(wc -w <<< "$cl") shared, $(( $(wc -w <<< "$bl") - $(wc -w <<< "$cl") )) on top)" ;;
    *) nok "T6 ros-base diff_ids do not start with ros-core's" ;;
esac

# --- T7: ros-base's tool set is the official ros-base's -----------------------
pkgs() { docker run --rm --platform "$PLATFORM" --network none --entrypoint dpkg-query "$1" -W -f '${Package}\n' | sort -u; }
ensure "$official_core"; ensure "$official_base"
tmp=$(mktemp -d); trap 'cleanup; rm -rf "$tmp"' EXIT
ocl=$(docker image inspect -f '{{join .RootFS.Layers " "}}' "$official_core")
obl=$(docker image inspect -f '{{join .RootFS.Layers " "}}' "$official_base")
case "$obl " in "$ocl "*) ok "T7 the pinned official ros-base is built on the pinned official ros-core (same upstream build)" ;;
    *) nok "T7 the pinned official ros-base is NOT built on the pinned official ros-core: re-pin the pair" ;; esac
pkgs "$official_core" > "$tmp/oc"; pkgs "$official_base" > "$tmp/ob"
pkgs "$core" > "$tmp/hc"; pkgs "$base" > "$tmp/hb"
comm -13 "$tmp/oc" "$tmp/hc" > "$tmp/core_added"      # what our ros-core adds
comm -23 "$tmp/oc" "$tmp/hc" > "$tmp/core_removed"    # what it drops (ros2-apt-source)
comm -13 "$tmp/ob" "$tmp/hb" > "$tmp/base_extra"
comm -23 "$tmp/ob" "$tmp/hb" > "$tmp/base_missing"
unexplained_extra=$(comm -23 "$tmp/base_extra" "$tmp/core_added")
unexplained_missing=$(comm -23 "$tmp/base_missing" "$tmp/core_removed")
echo "  official ros-base $(wc -l < "$tmp/ob") packages, ours $(wc -l < "$tmp/hb"); ours adds $(wc -l < "$tmp/base_extra") (all from ros-core's additions: RMWs and their deps), lacks: $(tr '\n' ' ' < "$tmp/base_missing")"
check "T7 ros-base package set = official ros-base + our ros-core additions (versions ignored)" test -z "$unexplained_extra$unexplained_missing"
[ -z "$unexplained_extra" ] || echo "  not in the official ros-base and not ours: $unexplained_extra"
[ -z "$unexplained_missing" ] || echo "  missing from ours: $unexplained_missing"
out=$(in_img "$base" none <<'EOF' 2>&1
for c in colcon rosdep vcs git gcc g++ make; do command -v $c >/dev/null || { echo "no $c"; exit 1; }; done
[ -s /etc/ros/rosdep/sources.list.d/20-default.list ] || { echo "rosdep not initialised"; exit 1; }
[ -d /root/.ros/rosdep/sources.cache ] || { echo "no rosdep cache"; exit 1; }
colcon mixin list 2>/dev/null | grep -q . || { echo "no colcon mixins"; exit 1; }
echo tools-ok
EOF
)
check "T7 ros-base tools: colcon (+mixins), rosdep (init + update), vcs, git, gcc" grep -q tools-ok <<< "$out"

# --- T8: the entrypoint sources ROS_OVERLAYS in order --------------------------
out=$(docker run --rm --platform "$PLATFORM" --network none --entrypoint bash -e ROS_OVERLAYS=/tmp/ov1:/tmp/ov2/setup.bash "$core" -c '
    mkdir -p /tmp/ov1 /tmp/ov2
    echo "export OV1=one" > /tmp/ov1/setup.bash
    echo "export OV2=\"two-after-\$OV1\"" > /tmp/ov2/setup.bash
    /ros_entrypoint.sh bash -c "echo \"\$OV1 \$OV2 \$AMENT_PREFIX_PATH\""' 2>&1)
check "T8 entrypoint: ROS sourced, then ROS_OVERLAYS in order ($out)" grep -qx "one two-after-one /opt/ros/${distro}" <<< "$out"
docker run --rm --platform "$PLATFORM" --network none -e ROS_OVERLAYS=/nonexistent "$core" true >/dev/null 2>&1
check "T8 entrypoint: a missing overlay fails the start" test $? != 0

# --- T5: a child installs from the snapshot without upgrading the base --------
app=$(child app <<EOF
FROM $core
RUN dpkg-query -W -f '\${Package} \${Version}\n' | sort > /before \
 && apt-get update \
 && apt-get install -y --no-install-recommends ros-${distro}-demo-nodes-cpp \
 && dpkg-query -W -f '\${Package} \${Version}\n' | sort > /after \
 && (apt list --installed 2>/dev/null | grep -E '\[installed[^]]*(local|upgradable)' | grep -v '^${fpkg}/' > /offsnapshot || true) \
 && apt-cache policy ros-${distro}-demo-nodes-cpp | grep -A1 '^ \*\*\*' > /from \
 && rm -rf /var/lib/apt/lists/*
RUN husarion-base-check
EOF
) || app=""
if [ -n "$app" ]; then
    out=$(docker run --rm --platform "$PLATFORM" --network none --entrypoint bash "$app" -c '
        echo "changed=$(comm -23 /before /after | wc -l) added=$(comm -13 /before /after | wc -l) offsnapshot=$(wc -l < /offsnapshot)"
        comm -23 /before /after | head; cat /offsnapshot | head; cat /from')
    echo "$out" | sed 's/^/  /'
    check "T5 child apt install: 0 base packages changed, all from the snapshot, base-check OK" \
        bash -c 'grep -q "changed=0 " <<< "$1" && grep -q "offsnapshot=0" <<< "$1" && grep -q "snapshots.ros.org/'"$distro/$ros_snapshot"'" <<< "$1"' _ "$out"
else
    nok "T5 child apt install (build failed)"
fi

# --- T3: talker/listener round trip under each RMW -----------------------------
if [ -n "$app" ]; then
    for rmw in rmw_fastrtps_cpp rmw_cyclonedds_cpp rmw_zenoh_cpp; do
        out=$(in_img "$app" none -e RMW_IMPLEMENTATION=$rmw -e RT=$rt_timeout <<'EOF' 2>&1
pids=()
if [ "$RMW_IMPLEMENTATION" = rmw_zenoh_cpp ]; then ros2 run rmw_zenoh_cpp rmw_zenohd >/tmp/zenohd.log 2>&1 & pids+=($!); sleep 2; fi
start=$(date +%s.%N)
ros2 run demo_nodes_cpp listener > /tmp/l.log 2>&1 & pids+=($!)
ros2 run demo_nodes_cpp talker > /tmp/t.log 2>&1 & pids+=($!)
for i in $(seq 1 $((RT * 2))); do
    n=$(grep -c "I heard" /tmp/l.log); [ "$n" -ge 3 ] && break; sleep 0.5
done
end=$(date +%s.%N)
kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null
n=$(grep -c "I heard" /tmp/l.log)
echo "heard=$n published=$(grep -c Publishing /tmp/t.log) secs=$(echo "$end - $start" | bc 2>/dev/null || python3 -c "print(round($end-$start,1))")"
[ "$n" -ge 3 ] || { tail -5 /tmp/l.log /tmp/t.log; exit 1; }
EOF
)
        rc=$?
        check "T3 round trip $rmw: $(grep -o 'heard=.*' <<< "$out" | head -1)" test "$rc" = 0
        [ "$rc" = 0 ] || echo "$out" | sed 's/^/  /'
    done
else
    nok "T3 round trip (no child image)"
fi

# --- T4: husarion-base-check catches a Fast DDS swap; §10.7.2 ------------------
before=$(docker run --rm --platform "$PLATFORM" --entrypoint dpkg-query "$core" -W -f '${Version}' "$fpkg")
after=$(docker run --rm -i --platform "$PLATFORM" --memory "$mem" --entrypoint bash "$core" -s <<EOF 2>/dev/null | tail -1
apt-get update >/dev/null 2>&1; apt-get install -y $fpkg >/dev/null 2>&1; echo "rc=\$?"; dpkg-query -W -f '\${Version}' $fpkg
EOF
)
check "T4 apt-get install $fpkg on the base leaves it at $before (got $after)" test "$after" = "$before"
swap=$(child swap <<EOF
FROM $core
RUN apt-get update \
 && stock=\$(apt-cache madison $fpkg | awk -F'|' '{gsub(/ /,"",\$2); print \$2}' | grep -v husarion | head -1) \
 && echo "swapping to \$stock" \
 && apt-get install -y --allow-change-held-packages --allow-downgrades $fpkg=\$stock \
 && rm -rf /var/lib/apt/lists/*
EOF
) || swap=""
if [ -n "$swap" ]; then
    sv=$(docker run --rm --platform "$PLATFORM" --entrypoint dpkg-query "$swap" -W -f '${Version}' "$fpkg")
    msg=$(docker run --rm --platform "$PLATFORM" --network none "$swap" husarion-base-check 2>&1); rc=$?
    echo "  swapped child: $fpkg $sv; check rc=$rc: $(head -2 <<< "$msg" | tr '\n' ' ')"
    check "T4 swapped child really has stock Fast DDS ($sv)" bash -c 'case "$1" in *husarion*|"") exit 1;; esac' _ "$sv"
    check "T4 husarion-base-check FAILS on the swapped child" bash -c '[ "$1" != 0 ] && grep -q "replaced" <<< "$2"' _ "$rc" "$msg"
else
    nok "T4 swap child (build failed)"
fi

echo
echo "== $distro $PLATFORM: $pass passed, $failn failed"
printf '%s\n' "${results[@]}"
[ "$failn" = 0 ]
