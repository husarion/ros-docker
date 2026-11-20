set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# Build both families of <distro> locally (never pushed). platform: linux/amd64 | linux/arm64.
build distro platform="":
    scripts/build.sh {{distro}} {{platform}}

# Test the local build of <distro> (test/run.sh; PLATFORM for another arch).
test distro platform="":
    PLATFORM="{{platform}}" test/run.sh {{distro}}

# Compressed and uncompressed sizes of the local build against the official images.
sizes distro platform="":
    scripts/sizes.sh {{distro}} {{platform}}

# Cut a release of <distro>: guard build + test, CHANGELOG, tag, push. CI pushes the images.
release distro:
    scripts/release.sh {{distro}}
