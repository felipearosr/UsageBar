#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TAG=${1:-$(git -C "$SCRIPT_DIR/.." describe --tags --abbrev=0)}
"$SCRIPT_DIR/mac-release" check-assets "$TAG"

# Asset presence alone cannot detect a damaged or incorrectly signed release.
source "$SCRIPT_DIR/release_artifacts.sh"
ARCHIVE=$(codexbar_app_zip_name "${TAG#v}" "${ARCHES:-arm64 x86_64}")
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-release-assets.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 300 \
  "https://github.com/steipete/CodexBar/releases/download/$TAG/$ARCHIVE" \
  --output "$TEMP_DIR/$ARCHIVE"
ditto -x -k --norsrc "$TEMP_DIR/$ARCHIVE" "$TEMP_DIR"
if [[ ! -d "$TEMP_DIR/CodexBar.app" || -L "$TEMP_DIR/CodexBar.app" ]]; then
  echo "Release archive must contain a real CodexBar.app directory." >&2
  exit 1
fi
REQUIREMENT='=anchor apple generic and identifier "com.steipete.codexbar"'
REQUIREMENT+=' and certificate leaf[subject.OU] = "Y5PE65HELJ"'
REQUIREMENT+=' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
REQUIREMENT+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
codesign --verify --deep --strict --all-architectures --verbose=2 \
  --test-requirement "$REQUIREMENT" "$TEMP_DIR/CodexBar.app"
echo "Release $TAG downloaded app signature verified (all architectures)."
