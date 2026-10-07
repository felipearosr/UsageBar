#!/usr/bin/env bash
# UsageBar fork delta report (fork-owned; see linux/upstream/FORK-DELTA.md).
#
# Diffs the checkout against its merge-base with upstream (steipete/CodexBar)
# and sorts every changed path into one of four groups:
#
#   linux/                    the Linux port; upstream doesn't have it
#   fork-owned                a file upstream doesn't have at the merge-base
#   allowlisted hooks         an upstream file the fork edits, listed in the allowlist
#   unlisted upstream edits   an upstream file the fork edits without declaring it
#
# Exits 1 when there is an unlisted upstream edit, or when an allowlist entry
# no longer matches an edited upstream file (stale; remove the line). Exits 2
# on usage errors, a missing upstream ref, or a malformed allowlist.
#
#   fork-delta.sh [--upstream <ref>] [--head <rev>] [--allowlist <path>] [--allow-stale] [--verbose]
#
#   --upstream <ref>    upstream ref to take the merge-base with (default: upstream/main)
#   --head <rev>        compare this commit instead of the working tree
#   --allowlist <path>  repo-relative allowlist (default: linux/upstream/hook-allowlist.tsv)
#   --allow-stale       report stale allowlist entries without failing (the merge rehearsal
#                       uses it, since taking upstream's side there drops fork hooks)
#   --verbose           also list every fork-owned file
#
# The allowlist is tab-separated: <upstream path> <TAB> <fork feature> [<TAB> note].
# Blank lines and lines starting with '#' are ignored.

set -euo pipefail

UPSTREAM_REF="${FORK_DELTA_UPSTREAM_REF:-upstream/main}"
ALLOWLIST="${FORK_DELTA_ALLOWLIST:-linux/upstream/hook-allowlist.tsv}"
HEAD_REV=""
ALLOW_STALE=0
VERBOSE=0

die() {
  printf 'fork-delta: %s\n' "$*" >&2
  exit 2
}

usage() {
  sed -n '/^#   fork-delta.sh/,/^#   --verbose/{s/^# \{0,1\}//;p}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) [[ $# -ge 2 ]] || die "--upstream needs a ref"; UPSTREAM_REF="$2"; shift 2 ;;
    --head) [[ $# -ge 2 ]] || die "--head needs a revision"; HEAD_REV="$2"; shift 2 ;;
    --allowlist) [[ $# -ge 2 ]] || die "--allowlist needs a path"; ALLOWLIST="$2"; shift 2 ;;
    --allow-stale) ALLOW_STALE=1; shift ;;
    -v | --verbose) VERBOSE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"

upstream_sha="$(git rev-parse --verify --quiet "${UPSTREAM_REF}^{commit}")" \
  || die "unknown upstream ref '${UPSTREAM_REF}'. Fetch it first:
  git remote add upstream https://github.com/steipete/CodexBar.git
  git fetch upstream main"
head_sha="$(git rev-parse --verify --quiet "${HEAD_REV:-HEAD}^{commit}")" || die "unknown revision '${HEAD_REV}'"
base="$(git merge-base "$head_sha" "$upstream_sha")" \
  || die "no merge-base between ${HEAD_REV:-HEAD} and ${UPSTREAM_REF} (shallow clone? fetch full history)"
base_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$base" 2>/dev/null || printf 'no tag')"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Allowlist: from the working tree, or from the compared commit with --head.
if [[ -n "$HEAD_REV" ]]; then
  git show "${head_sha}:${ALLOWLIST}" > "$tmp/allowlist.raw" 2>/dev/null || : > "$tmp/allowlist.raw"
elif [[ -f "$ALLOWLIST" ]]; then
  cp "$ALLOWLIST" "$tmp/allowlist.raw"
else
  : > "$tmp/allowlist.raw"
fi
# Validate it and keep "<line>\t<path>\t<feature>" per entry.
awk -F'\t' -v file="$ALLOWLIST" '
  /^[[:space:]]*(#|$)/ { next }
  {
    if (NF < 2 || $1 == "" || $2 ~ /^[[:space:]]*$/) {
      printf "fork-delta: %s:%d: want <path><TAB><fork feature>[<TAB>note], got: %s\n", file, FNR, $0 > "/dev/stderr"
      bad = 1; next
    }
    if ($1 ~ /^linux\//) {
      printf "fork-delta: %s:%d: %s is under linux/, which never needs an entry\n", file, FNR, $1 > "/dev/stderr"
      bad = 1; next
    }
    if ($1 in seen) {
      printf "fork-delta: %s:%d: %s is already listed on line %d\n", file, FNR, $1, seen[$1] > "/dev/stderr"
      bad = 1; next
    }
    seen[$1] = FNR
    printf "%d\t%s\t%s\n", FNR, $1, $2
  }
  END { exit bad }
' "$tmp/allowlist.raw" > "$tmp/allowlist" || die "fix the allowlist entries above"

git ls-tree -r --name-only "$base" > "$tmp/upstream-files"
diff_target=("$base")
[[ -n "$HEAD_REV" ]] && diff_target+=("$head_sha")
git -c core.quotePath=false diff --no-renames --name-status "${diff_target[@]}" > "$tmp/changes"
git -c core.quotePath=false diff --no-renames --numstat "${diff_target[@]}" > "$tmp/numstat"

# "<group>\t<status>\t<path>\t<+added>\t<-deleted>" for every changed path.
awk -F'\t' '
  FILENAME == ARGV[1] { allowed[$2] = 1; next }
  FILENAME == ARGV[2] { upstream[$0] = 1; next }
  FILENAME == ARGV[3] { added[$3] = $1; deleted[$3] = $2; next }
  {
    status = substr($1, 1, 1); path = $2
    if (path ~ /^linux\//) group = "linux"
    else if (!(path in upstream)) group = "fork"
    else if (path in allowed) group = "hook"
    else group = "unlisted"
    printf "%s\t%s\t%s\t%s\t%s\n", group, status, path, added[path], deleted[path]
  }
' "$tmp/allowlist" "$tmp/upstream-files" "$tmp/numstat" "$tmp/changes" > "$tmp/classified"

count() { awk -F'\t' -v g="$1" '$1 == g { n++ } END { print n + 0 }' "$tmp/classified"; }
n_linux="$(count linux)"
n_fork="$(count fork)"
n_hook="$(count hook)"
n_unlisted="$(count unlisted)"

# Allowlist entries that match no edited upstream file.
awk -F'\t' '
  FILENAME == ARGV[1] { if ($1 == "hook") hooked[$3] = 1; next }
  !($2 in hooked) { printf "%s\t%s\t%s\n", $1, $2, $3 }
' "$tmp/classified" "$tmp/allowlist" > "$tmp/stale"
n_stale="$(wc -l < "$tmp/stale" | tr -d ' ')"

compared="working tree"
[[ -n "$HEAD_REV" ]] && compared="${HEAD_REV} (${head_sha:0:9})"
printf 'Fork delta: %s vs %s\n' "$compared" "$UPSTREAM_REF"
printf 'Merge-base: %s (%s)\n\n' "${base:0:9}" "$base_tag"
printf '  %-26s %4d files\n' "linux/" "$n_linux" "fork-owned" "$n_fork" \
  "allowlisted hooks" "$n_hook" "unlisted upstream edits" "$n_unlisted"

if [[ "$n_hook" -gt 0 ]]; then
  printf '\nAllowlisted hooks, by fork feature (%s):\n' "$ALLOWLIST"
  # Features in allowlist order; files in allowlist order within each feature.
  awk -F'\t' '
    FILENAME == ARGV[1] { if ($1 == "hook") { hook[$3] = $2 "\t+" $4 " -" $5 } ; next }
    ($2 in hook) {
      if (!($3 in seen)) { seen[$3] = 1; order[++features] = $3 }
      lines[$3] = lines[$3] sprintf("    %s %s  %s\n", substr(hook[$2], 1, 1), $2, substr(hook[$2], 3))
      count[$3]++
    }
    END {
      for (i = 1; i <= features; i++) {
        printf "  %s (%d)\n%s", order[i], count[order[i]], lines[order[i]]
      }
    }
  ' "$tmp/classified" "$tmp/allowlist"
fi

if [[ "$VERBOSE" == 1 && "$n_fork" -gt 0 ]]; then
  printf '\nFork-owned files:\n'
  awk -F'\t' '$1 == "fork" { printf "    %s %s\n", $2, $3 }' "$tmp/classified"
fi

if [[ "$n_stale" -gt 0 ]]; then
  printf '\nStale allowlist entries (the fork no longer edits these upstream files; remove the lines):\n'
  awk -F'\t' -v file="$ALLOWLIST" '{ printf "    %s:%s %s (%s)\n", file, $1, $2, $3 }' "$tmp/stale"
fi

if [[ "$n_unlisted" -gt 0 ]]; then
  printf '\nUnlisted upstream edits:\n'
  awk -F'\t' '$1 == "unlisted" { printf "    %s %s  +%s -%s\n", $2, $3, $4, $5 }' "$tmp/classified"
fi

status=0
printf '\n'
if [[ "$n_unlisted" -gt 0 ]]; then
  printf 'FAIL: %d upstream file(s) edited without an allowlist entry. Move the change into a fork-owned file,\n' \
    "$n_unlisted"
  printf '      or add "<path><TAB><fork feature>" to %s (see linux/upstream/FORK-DELTA.md).\n' "$ALLOWLIST"
  status=1
fi
if [[ "$n_stale" -gt 0 ]]; then
  if [[ "$ALLOW_STALE" == 1 ]]; then
    printf 'NOTE: %d stale allowlist entr(y/ies), allowed by --allow-stale.\n' "$n_stale"
  else
    printf 'FAIL: %d stale allowlist entr(y/ies). Remove them from %s.\n' "$n_stale" "$ALLOWLIST"
    status=1
  fi
fi
if [[ "$status" == 0 ]]; then
  printf 'OK: every upstream file the fork edits is on the allowlist.\n'
fi
exit "$status"
