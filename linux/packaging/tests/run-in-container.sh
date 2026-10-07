#!/bin/sh
# Runs one packaging smoke test in a fresh container:
#
#   run-in-container.sh IMAGE TEST ARTIFACT_DIR [ENV=VALUE...]
#
# TEST is a script in this directory (install-script.sh, ...). The checkout is
# mounted read-only at /src and ARTIFACT_DIR at /artifacts. Uses podman, or
# docker when podman is missing (CONTAINER_ENGINE overrides).
set -eu

image=$1
test=$2
artifacts=$(cd "$3" && pwd)
shift 3
repo=$(cd "$(dirname "$0")/../../.." && pwd)
engine=${CONTAINER_ENGINE:-$(command -v podman || command -v docker)}
[ -n "$engine" ] || { echo "need podman or docker" >&2; exit 1; }

# Turn the remaining ENV=VALUE arguments into -e flags.
n=$#
while [ "$n" -gt 0 ]; do
    set -- "$@" -e "$1"
    shift
    n=$((n - 1))
done
exec "$engine" run --rm --security-opt label=disable \
    -v "$repo:/src:ro" -v "$artifacts:/artifacts:ro" "$@" \
    "$image" sh "/src/linux/packaging/tests/$test" /artifacts
