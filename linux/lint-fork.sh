#!/usr/bin/env bash
# UsageBar fork-only lint checks (fork-owned).
#
# Upstream's Scripts/lint.sh calls this from run_portable_checks through a
# single hook line, so `make check`, `make lint` and CI's `lint.sh lint-linux`
# run it. Add fork checks here instead of editing Scripts/lint.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_machine_sync_vectors() {
  node --test "${ROOT_DIR}/docs/machine-sync-test-vectors/reference.test.mjs"
  node "${ROOT_DIR}/docs/machine-sync-test-vectors/reference.mjs" --check
}

check_machine_sync_vectors
