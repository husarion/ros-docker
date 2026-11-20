# husarion/ros

The ROS 2 base images under every Husarion ROS image (the UGV OS containers:
driver, rosbridge, camera, crsf-pilot, asset-server, airlock). Published as
[`husarion/ros`](https://hub.docker.com/r/husarion/ros) on Docker Hub, for
Jazzy, Humble and Lyrical, amd64 and arm64.

They are the official [`ros`](https://hub.docker.com/_/ros) images plus what
all our images share, built once, so every image on a robot stores those
layers once.

## Tags

| Tag | |
| -- | -- |
| `husarion/ros:<distro>-ros-core-YYYYMMDD[.N]` | immutable, pushed once |
| `husarion/ros:<distro>-ros-base-YYYYMMDD[.N]` | immutable, pushed once |
| `husarion/ros:<distro>-ros-core` | the newest release; moves |
| `husarion/ros:<distro>-ros-base` | the newest release; moves |

`<distro>` is `jazzy`, `humble` or `lyrical`. Each distro is released on its
own (tag `<distro>-YYYYMMDD[.N]`); the GitHub release of that tag lists the
index digests. The undated tags are a convenience: **an image we ship never
builds FROM a tag**, only from a dated tag pinned by digest. The 2022 tag
`humble-ros-core` is overwritten by the first Humble release; the other 2022
tags (foxy, galactic, ros1-bridge) are left as they are and no longer built.

## What each family contains

**`ros-core`** = `ros:<distro>-ros-core` at the digest pinned in
[`distros.env`](distros.env), plus, in one layer:

1. **apt sources pinned to snapshots**: `snapshots.ros.org/<distro>/<date>`
   (signing key `keys/ros-snapshots.asc`, fingerprint checked at build) and
   `snapshot.ubuntu.com/ubuntu/<timestamp>` (all four pockets). The live
   `packages.ros.org` source and `ros2-apt-source` are removed. A child image
   built weeks later therefore installs from the same ROS sync the base was
   built on, never newer packages on older libraries.
2. **The patched Fast DDS** from
   [husarion/fastdds-patched](https://github.com/husarion/fastdds-patched)
   (`+husarion<N>`), downloaded from its release and checked against the
   sha256 pinned per distro and architecture, installed **before** the
   upgrade, `apt-mark hold`, and pinned in `/etc/apt/preferences.d/husarion-fastdds`.
   The build also checks the snapshot carries exactly the stock build the
   `.deb` was made from.
3. One `apt-get upgrade`, against the snapshot.
4. The three RMWs: `rmw-cyclonedds-cpp`, `rmw-fastrtps-cpp`, `rmw-zenoh-cpp`.
   `RMW_IMPLEMENTATION` is left unset (each image or deployment chooses).
5. `/etc/apt/apt.conf.d/80-retries` (`Acquire::Retries "8"`).
6. `/usr/local/bin/husarion-base-check` (below).
7. `/ros_entrypoint.sh`: sources `/opt/ros/$ROS_DISTRO/setup.bash`, then each
   entry of `ROS_OVERLAYS` (colon-separated, in order; a workspace install
   directory or a `setup.bash`; a missing entry fails the start), then
   `exec "$@"`.
8. Labels: `com.husarion.ros.fastdds`, `com.husarion.ros.fastdds-release`,
   `org.opencontainers.image.base.name`/`.base.digest` (the official image),
   `com.husarion.ros.snapshot.ros`, `com.husarion.ros.snapshot.ubuntu`,
   `org.opencontainers.image.revision` (this repository's commit).

The build fails if any installed package is newer than, or absent from, the
snapshot (other than the patched Fast DDS).

**`ros-base`** = our `ros-core` (the same layers, byte for byte) plus exactly
what the official `ros:<distro>-ros-base` Dockerfile adds
([osrf/docker_images](https://github.com/osrf/docker_images)): `build-essential`,
`git`, `python3-colcon-common-extensions`, `python3-colcon-mixin`,
`python3-rosdep`, `python3-vcstool`, `rosdep init` + `rosdep update`, the
default colcon mixin and metadata, then `ros-<distro>-ros-base` at the
upstream version.

### Differences from the official images

- apt resolves against the pinned snapshots, not the live repositories;
  `ros2-apt-source` is not installed.
- Fast DDS is the patched, held `+husarion` build.
- All three RMWs are installed.
- Packages are upgraded to the snapshot (official images carry whatever their
  build day had).
- `/ros_entrypoint.sh` also sources `ROS_OVERLAYS`.
- ros-base has the same package set as the official one plus our RMWs and
  their dependencies (test/ checks this against the official image).

## Rules for an image built on husarion/ros

1. `FROM` a **dated tag by digest**, through an argument, for the runtime
   stage **and** any builder stage: `ARG ROS_BASE=husarion/ros:jazzy-ros-base-YYYYMMDD@sha256:<index digest>`.
   Never the official `ros` image in a builder: its libraries differ from the
   upgraded base.
2. No `apt-get upgrade`, and do not reinstall the RMWs or Fast DDS. An upgrade
   copies base packages into the child's layer, undoes the sharing, and is how
   a held Fast DDS gets replaced.
3. `apt-get update` only in the same `RUN` as the install, ending with
   `rm -rf /var/lib/apt/lists/*`.
4. **`RUN husarion-base-check` as the last `RUN`.** It fails the build when a
   held package (the patched Fast DDS) was replaced, unheld, lost `+husarion`
   or had files overwritten, when the apt pin is gone, when another Fast DDS
   library appears outside `/opt/ros/$ROS_DISTRO`, or when a source points at
   the live `packages.ros.org`.
5. Keep your own entrypoint if you need one, and call `/ros_entrypoint.sh`
   from it (or set `ROS_OVERLAYS` and use ours).
6. The child's CI checks that its first layers (diff_ids, on the arm64 entry)
   are exactly the base's.

## Building and testing locally

```bash
just build jazzy                 # husarion/ros:jazzy-ros-{core,base}-local
just build jazzy linux/arm64     # ...-local-arm64 (qemu binfmt needed on amd64)
just test jazzy                  # test/run.sh on the local build
just test jazzy linux/arm64
just sizes jazzy                 # against the official images
```

Nothing local is ever pushed. `DOCKER_HOST=ssh://<host>` builds and tests on
another engine (the scripts only use the docker CLI). `FASTDDS_DEB_LOCAL=<path
in this directory>` builds with a local `.deb` (its sha256 must still match
`distros.env`).

`test/run.sh <distro> [core-ref] [base-ref]` checks: Fast DDS `+husarion` held
and pinned; the three RMWs; a talker/listener round trip under each RMW;
`husarion-base-check` passes on both families and fails on a child that swaps
Fast DDS to the stock build; `apt-get install` of the Fast DDS package leaves
it alone; a child's `apt-get install` resolves from the snapshot and changes
no base package; ros-base's layers start with ros-core's; ros-base's package
set and tools match the official ros-base; the entrypoint sources
`ROS_OVERLAYS` in order. ROS processes run with `--network none`, domain 88
and localhost-only discovery.

## Releasing

```bash
just release jazzy                      # or humble, lyrical
RELEASE_DRY_RUN=1 just release jazzy    # stops before the commit
```

`just release <distro>` refuses unless the tree is clean, `HEAD` is
`origin/main`, and today's next free version is neither a git tag nor on
Docker Hub. It builds and tests locally as a guard, asks y/N, adds the
CHANGELOG section, commits, tags `<distro>-YYYYMMDD[.N]` and pushes the commit
and the tag. It never pushes images.

The tag's workflow (`.github/workflows/release.yml`) builds each architecture
on its native runner, pushes both families **by digest only**, runs `test/`
against those digests on each architecture, and only then creates the dated
and undated multi-arch tags and the GitHub release with both index digests.
It needs the secrets `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` (read-only, for
the official images) and `DOCKERHUB_OAT` (the org token, pushes husarion/ros).

`.github/workflows/security-check.yml` runs weekly and fails when Ubuntu has
security updates for a published base since its snapshot; it also reports
ROS packages synced since the snapshot. A new base is cut when fastdds-patched
releases, when a ROS sync or a security fix is needed, otherwise at most
monthly.

## Refreshing a pin

Edit `distros.env` in its own commit: the official digests (ros-core and the
matching ros-base of the same upstream build), the snapshot dates, or the
fastdds-patched release and its `.deb` sha256s (from the release's
`SHA256SUMS`). A ROS snapshot must carry exactly the stock Fast DDS build the
patched `.deb` was made from; the build stops otherwise. Then
`just release <distro>`.
