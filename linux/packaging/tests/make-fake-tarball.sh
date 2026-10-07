#!/bin/sh
# Writes a stand-in CLI tarball (and .sha256) with the release layout, so the
# packaging smoke tests can run in CI without building the Swift CLI:
#
#   make-fake-tarball.sh OUT_DIR [VERSION] [ARCH]
#
# Its CodexBarCLI is a shell script that answers the cli-checks.sh probes the
# way the real binary does, including finding the resource bundle next to its
# resolved path.
set -eu

out=$1
version=${2:-0.0.0-fake}
arch=${3:-$(uname -m)}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/CodexBarCLI" <<'EOF'
#!/bin/sh
dir=$(dirname "$(readlink -f "$0")")
if [ "${CODEXBAR_RESOURCE_SMOKE:-}" = 1 ]; then
    [ -f "$dir/CodexBar_CodexBarCore.bundle/provider-plugin-prelude.js" ] || {
        echo "RESOURCE SMOKE FAILURE: bundle missing next to $dir" >&2
        exit 1
    }
    echo CODEXBAR_RESOURCE_SMOKE_OK
    exit 0
fi
case "${1:-}" in
    --version | -V) echo "CodexBar $(cat "$dir/VERSION")" ;;
    --help | -h) printf 'CodexBar %s\n\nUsage:\n  codexbar usage\n' "$(cat "$dir/VERSION")" ;;
    sync) printf 'Usage:\n  codexbar sync status\n' ;;
    *) echo "fake codexbar" ;;
esac
EOF
chmod 0755 "$work/CodexBarCLI"
ln -s CodexBarCLI "$work/codexbar"
printf '%s\n' "$version" > "$work/VERSION"
mkdir "$work/CodexBar_CodexBarCore.bundle"
echo '// fake' > "$work/CodexBar_CodexBarCore.bundle/provider-plugin-prelude.js"

mkdir -p "$out"
name="usagebar-cli-$version-linux-$arch.tar.gz"
(cd "$work" && tar -czf "$name" CodexBarCLI codexbar VERSION CodexBar_CodexBarCore.bundle)
mv "$work/$name" "$out/$name"
(cd "$out" && sha256sum "$name" > "$name.sha256")
printf '%s\n' "$out/$name"
