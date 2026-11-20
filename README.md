# ros-docker

`husarion/ros` images: the official ROS 2 images plus what every Husarion ROS image shares.

| Image | Built from | Adds |
| -- | -- | -- |
| `husarion/ros:<distro>-ros-core` | `ros:<distro>-ros-core`, pinned by digest | apt pinned to dated ROS and Ubuntu snapshots, the patched Fast DDS from [fastdds-patched](https://github.com/husarion/fastdds-patched) (held), one upgrade, the Cyclone DDS, Fast DDS and Zenoh RMWs |
| `husarion/ros:<distro>-ros-base` | `husarion/ros:<distro>-ros-core` | what the official `ros-base` adds: build tools, rosdep, colcon, vcstool, `ros-<distro>-ros-base` |

Distros: Jazzy, Humble, Lyrical. Platforms: amd64, arm64. Each release also has dated tags,
`<distro>-ros-core-YYYYMMDD[.N]` and `<distro>-ros-base-YYYYMMDD[.N]`; pin those (by digest) in your Dockerfiles.

Because apt points at the snapshots, an image built on this base later installs the package versions the base was
built with. Don't run `apt-get upgrade` in images built on it, and don't replace the held Fast DDS package.

## Usage

```
just build jazzy     # local build
just smoke jazzy     # Fast DDS held and patched, RMWs present
just release         # tag YYYYMMDD[.N] and push it; CI builds all distros x amd64+arm64, tests and publishes
```

The pins live in `distros.env`. Updating means editing a distro's line (a new official digest, newer snapshot dates, or a new
fastdds-patched release) and running `just release`; every release rebuilds all distros under one date.

CI needs the `DOCKERHUB_OAT` secret: a Docker Hub organization access token with write access to `husarion/ros`.
