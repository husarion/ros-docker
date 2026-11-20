#!/bin/bash
# release.sh <distro>: cut a husarion/ros release of one distro (both families).
# It never pushes an image: it builds and tests locally as a guard, then
# commits the CHANGELOG, tags <distro>-YYYYMMDD[.N] and pushes the commit and
# the tag; the tag's CI (.github/workflows/release.yml) builds both
# architectures natively, tests the pushed digests and only then tags them.
# Refuses unless: the tree is clean, HEAD == origin/main, and neither the git
# tag nor the dated Docker Hub tags of today's next free version exist (Hub
# checked anonymously; only a 404 counts as free).
# RELEASE_DRY_RUN=1 stops before the commit (after the guard build and test).
# RELEASE_NOTES="..." adds a paragraph to the CHANGELOG section.
# DOCKER_HOST may point at another engine (ssh://host): build and test only
# use the docker CLI.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
distro=${1:?usage: just release <distro>}
case "$distro" in jazzy|humble|lyrical) ;; *) echo "unknown distro: $distro" >&2; exit 2 ;; esac
dry=${RELEASE_DRY_RUN:-0}
die() { echo "release: $*" >&2; exit 1; }
get() { scripts/build-args.sh "$distro" get "$1"; }

[ -z "$(git status --porcelain)" ] || die "the tree is not clean"
git fetch --quiet origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "HEAD $(git rev-parse --short HEAD) is not origin/main $(git rev-parse --short origin/main): push main first"

hub_free() { # 0 = free (404), 1 = taken (200), else abort
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 \
        "https://hub.docker.com/v2/namespaces/husarion/repositories/ros/tags/$1")
    case "$code" in
        404) return 0 ;;
        200) return 1 ;;
        *) die "Docker Hub answered $code for husarion/ros:$1; cannot tell whether it exists" ;;
    esac
}
today=$(date -u +%Y%m%d)
version=""
for n in "" .1 .2 .3 .4 .5 .6 .7 .8 .9; do
    cand="${today}${n}"
    git rev-parse -q --verify "refs/tags/${distro}-${cand}" >/dev/null && continue
    [ -z "$(git ls-remote --tags origin "refs/tags/${distro}-${cand}")" ] || continue
    hub_free "${distro}-ros-core-${cand}" || continue
    hub_free "${distro}-ros-base-${cand}" || continue
    version=$cand; break
done
[ -n "$version" ] || die "no free version for $today (tried up to .9)"
tag="${distro}-${version}"
echo "== release $tag: husarion/ros:${distro}-ros-core-${version} and :${distro}-ros-base-${version}"

echo "== guard: local build and test (the bytes CI pushes are built again there)"
scripts/build.sh "$distro"
test/run.sh "$distro"

core=$(get ROS_CORE)
section=$(cat <<EOF
## ${tag} ($(date -u +%Y-%m-%d))

husarion/ros:${distro}-ros-core-${version} and husarion/ros:${distro}-ros-base-${version} (also ${distro}-ros-core and ${distro}-ros-base).

- Official base: \`${core}\`
- ROS snapshot: ${distro}/$(get ROS_SNAPSHOT); Ubuntu snapshot: $(get UBUNTU_SNAPSHOT)
- Fast DDS: ros-${distro}-$(get FASTDDS_PKG) $(get FASTDDS_UPSTREAM)$(scripts/build-args.sh "$distro" get FASTDDS_SUFFIX), husarion/fastdds-patched $(scripts/build-args.sh "$distro" get FASTDDS_RELEASE), held
- Commit: $(git rev-parse --short HEAD)
${RELEASE_NOTES:+
${RELEASE_NOTES}
}
EOF
)
echo
echo "$section"
echo
if [ "$dry" = 1 ]; then
    echo "RELEASE_DRY_RUN=1: stopping before the commit. Would commit CHANGELOG.md, tag $tag and push main and $tag."
    exit 0
fi
read -r -p "Commit, tag $tag and push? [y/N] " ans
[ "$ans" = y ] || [ "$ans" = Y ] || die "aborted"

python3 - "$section" <<'PY'
import sys
p = "CHANGELOG.md"
s = open(p).read()
marker = "<!-- releases -->\n"
assert marker in s, "CHANGELOG.md lost its <!-- releases --> marker"
s = s.replace(marker, marker + "\n" + sys.argv[1].rstrip() + "\n", 1)
open(p, "w").write(s)
PY
git commit -q -o CHANGELOG.md -m "Release ${tag}"
git tag -a "$tag" -m "husarion/ros ${tag}"
git push --atomic origin HEAD:main "refs/tags/${tag}"
echo "== pushed $tag: CI builds, tests and promotes it (Actions tab of husarion/ros-docker)"
