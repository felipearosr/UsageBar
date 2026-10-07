# Shared helpers for the packaging smoke tests (sourced, POSIX sh).
# shellcheck shell=sh

say() { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The CLI's runtime libraries plus what the tests themselves use.
install_runtime_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates curl \
            libsqlite3-0 libstdc++6 diffutils >/dev/null
        apt-get install -y -qq --no-install-recommends libcurl4t64 >/dev/null 2>&1 \
            || apt-get install -y -qq --no-install-recommends libcurl4 >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q libcurl sqlite-libs libstdc++ diffutils findutils util-linux >/dev/null
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Syu --noconfirm --needed --quiet curl sqlite gcc-libs diffutils >/dev/null
    else
        fail "unsupported distro: no apt-get, dnf or pacman"
    fi
}

# Every path under $1 (or "absent"), for before/after comparisons.
snapshot() {
    if [ -e "$1" ]; then find "$1" | LC_ALL=C sort; else echo absent; fi
}

# Fails with a diff when the paths under $2 differ from snapshot $1.
assert_unchanged() {
    after=$(snapshot "$2")
    [ "$after" = "$1" ] && return 0
    printf '%s\n' "$1" > /tmp/snapshot.before
    printf '%s\n' "$after" > /tmp/snapshot.after
    diff -u /tmp/snapshot.before /tmp/snapshot.after >&2 || true
    fail "$3"
}

# Copy the artifacts somewhere every user can read them.
stage_artifacts() {
    rm -rf /tmp/art
    mkdir -p /tmp/art
    cp -R "$1"/. /tmp/art/
    chmod -R a+rX /tmp/art
}

# The single CLI tarball for this machine's architecture in $1.
find_tarball() {
    set -- "$1"/*-linux-"$(uname -m)".tar.gz
    if [ $# -ne 1 ] || [ ! -f "$1" ]; then fail "expected exactly one *-linux-$(uname -m).tar.gz"; fi
    printf '%s\n' "$1"
}

tarball_version() {
    tar -xzO -f "$1" VERSION | tr -d '[:space:]'
}
