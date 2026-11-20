set shell := ["bash", "-euo", "pipefail", "-c"]
# .env (gitignored) holds DOCKERHUB_OAT for the local CI checks; CI gets it from the repo secret.
set dotenv-load

image := "husarion/ros"

# List the recipes.
default:
    @just --list

# Build husarion/ros:<distro>-ros-core and -ros-base locally (for this machine's arch).
build distro:
    read -r _ codename core rsnap usnap pkg rel amd arm < <(grep "^{{distro}} " distros.env) || { echo "unknown distro {{distro}}"; exit 1; }; \
    for t in ros-core ros-base; do \
      docker build --target "$t" -t "{{image}}:{{distro}}-$t" \
        --build-arg ROS_CORE_IMAGE="$core" --build-arg CODENAME="$codename" \
        --build-arg ROS_SNAPSHOT="$rsnap" --build-arg UBUNTU_SNAPSHOT="$usnap" \
        --build-arg FASTDDS_PKG="$pkg" --build-arg FASTDDS_RELEASE="$rel" \
        --build-arg FASTDDS_SHA256_amd64="$amd" --build-arg FASTDDS_SHA256_arm64="$arm" . ; \
    done

# Smoke-test the local build of <distro>.
smoke distro:
    pkg=$(awk '$1 == "{{distro}}" {print $6}' distros.env); \
    for t in ros-core ros-base; do \
      docker run --rm -i -e FASTDDS_PKG="$pkg" -e FAMILY="$t" "{{image}}:{{distro}}-$t" bash -s < test/smoke.sh; \
    done

# Release every distro in distros.env: tags YYYYMMDD[.N] and pushes the tag; CI builds, tests and publishes.
release:
    @[ -z "$(git status --porcelain)" ] || { echo "the tree is not clean"; exit 1; }
    @git fetch -q --tags origin
    @[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "HEAD is not origin/main: push main first"; exit 1; }
    @base="$(date -u +%Y%m%d)"; tag="$base"; n=0; \
    while git rev-parse -q --verify "refs/tags/$tag" >/dev/null; do n=$((n+1)); tag="$base.$n"; done; \
    distros=$(awk '!/^#/ && NF {print $1}' distros.env | xargs); \
    echo "Release $tag: {{image}}:<distro>-ros-core-$tag and <distro>-ros-base-$tag for $distros, amd64 + arm64"; \
    read -rp "Tag and push $tag? [y/N] " a; \
    [ "$a" = y ] || { echo "nothing done"; exit 1; }; \
    git tag -a "$tag" -m "$tag" && git push origin "$tag"

# Ask Docker Hub what DOCKERHUB_OAT may do on husarion/ros (pushes nothing).
login-check:
    @[ -n "${DOCKERHUB_OAT:-}" ] || { echo "DOCKERHUB_OAT is not set (put it in .env)"; exit 1; }; \
    curl -fsS -u "husarion:$DOCKERHUB_OAT" \
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:{{image}}:pull,push" \
    | python3 -c 'import sys,json,base64; t=json.load(sys.stdin)["token"].split(".")[1]; t+="="*(-len(t)%4); a=json.loads(base64.urlsafe_b64decode(t)).get("access",[]); acts=[x for e in a for x in e.get("actions",[])]; print("token may:", ",".join(acts) or "nothing"); sys.exit(0 if "push" in acts else 1)'

# What CI does for <distro> on this machine, up to the push: login, the published check, build, smoke.
ci distro:
    @[ -n "${DOCKERHUB_OAT:-}" ] || { echo "DOCKERHUB_OAT is not set (put it in .env)"; exit 1; }; \
    export DOCKER_CONFIG=$(mktemp -d); trap 'rm -rf "$DOCKER_CONFIG"' EXIT; \
    printf '%s' "$DOCKERHUB_OAT" | docker login -u husarion --password-stdin >/dev/null; \
    v=$(date -u +%Y%m%d); \
    if docker manifest inspect "{{image}}:{{distro}}-ros-core-$v" >/dev/null 2>&1; then echo "{{image}}:{{distro}}-ros-core-$v is already published: the release would take the next .N"; fi; \
    just build {{distro}}; just smoke {{distro}}; \
    echo "ci {{distro}}: ok up to the push"
