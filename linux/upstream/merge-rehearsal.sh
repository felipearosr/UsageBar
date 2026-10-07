#!/usr/bin/env bash
# UsageBar merge rehearsal (fork-owned; see linux/upstream/RUNBOOK.md).
# shellcheck disable=SC2016  # Backticks in single quotes are Markdown, not command substitution.
#
# Merges an upstream ref into the current HEAD *locally*, records conflicts,
# resolves them with upstream's side so the build and tests can still run,
# records each check's result, and renders a Markdown report. It never pushes.
#
#   merge-rehearsal.sh merge  <upstream-ref> <out-dir>
#   merge-rehearsal.sh check  <out-dir> <name> -- <command...>
#   merge-rehearsal.sh skip   <out-dir> <name> <reason>
#   merge-rehearsal.sh report <out-dir>
#
# `check` always exits 0; the result lives in <out-dir>/checks.
# Run it in a scratch branch or a CI checkout: `merge` commits the merge.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
# Owned by the fork delta report (#52). The allowlist is tab-separated:
# <upstream path> <TAB> <fork feature> [<TAB> anything else]; '#' starts a comment.
FORK_DELTA_ALLOWLIST="${FORK_DELTA_ALLOWLIST:-linux/upstream/hook-allowlist.tsv}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-40}"
GIT_ID=(-c user.name="UsageBar merge rehearsal" -c user.email="merge-rehearsal@localhost")

die() {
  printf 'merge-rehearsal: %s\n' "$*" >&2
  exit 2
}

feature_for() {
  local path="$1" file="${ROOT_DIR}/${FORK_DELTA_ALLOWLIST}"
  [[ -f "$file" ]] || { printf '(no allowlist yet)'; return; }
  local feature
  feature="$(awk -F'\t' -v p="$path" '$0 !~ /^#/ && $1 == p { print $2; exit }' "$file")"
  printf '%s' "${feature:-NOT ALLOWLISTED}"
}

cmd_merge() {
  local ref="$1" out="$2"
  mkdir -p "$out/checks"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree must be clean"
  fi

  local base upstream ahead tag
  base="$(git rev-parse HEAD)"
  upstream="$(git rev-parse --verify "${ref}^{commit}")" || die "unknown ref: $ref"
  ahead="$(git rev-list --count "${base}..${upstream}")"
  tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$upstream" 2>/dev/null || printf 'none')"
  {
    printf 'ref=%s\n' "$ref"
    printf 'upstream_sha=%s\n' "$upstream"
    printf 'upstream_tag=%s\n' "$tag"
    printf 'fork_sha=%s\n' "$base"
    printf 'ahead=%s\n' "$ahead"
  } > "$out/meta"
  : > "$out/conflicts.tsv"

  if [[ "$ahead" == 0 ]]; then
    printf 'up-to-date\n' > "$out/merge-status"
    return 0
  fi

  if git "${GIT_ID[@]}" merge --no-ff --no-edit -m "Rehearse merge of ${ref}" "$upstream" > "$out/merge.log" 2>&1; then
    printf 'clean\n' > "$out/merge-status"
    return 0
  fi

  # Record every conflicted path: kind (UU, AA, UD, DU, ...), hunk count,
  # the fork feature from the allowlist, and the fork commits that touched it.
  local line kind path hunks commits
  while IFS= read -r line; do
    kind="${line:0:2}"
    path="${line:3}"
    hunks=0
    [[ -f "$path" ]] && hunks="$(grep -c '^<<<<<<< ' "$path" || true)"
    commits="$(git log --format='%h %s' -n 3 "${upstream}..${base}" -- "$path" | paste -sd ';' -)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$hunks" "$(feature_for "$path")" "$commits" \
      >> "$out/conflicts.tsv"
  done < <(git status --porcelain=v1 | grep -E '^(DD|AU|UD|UA|DU|AA|UU) ')
  printf 'conflicts\n' > "$out/merge-status"

  # Runbook policy: take upstream's side, then re-apply the fork change.
  # Redo the merge with conflicting hunks resolved to upstream so the checks
  # show which fork code needs re-applying.
  git merge --abort
  git "${GIT_ID[@]}" merge --no-ff --no-edit -X theirs -m "Rehearse merge of ${ref} (upstream side)" \
    "$upstream" >> "$out/merge.log" 2>&1 && return 0
  # Leftovers -X theirs can't settle (modify/delete, add/add): take upstream's file or deletion.
  while IFS= read -r path; do
    if git cat-file -e "${upstream}:${path}" 2>/dev/null; then
      git checkout "$upstream" -- "$path"
    else
      git rm -q -- "$path"
    fi
  done < <(git diff --name-only --diff-filter=U)
  git "${GIT_ID[@]}" commit -q --no-edit
}

cmd_check() {
  local out="$1" name="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  local slug="${name//[^A-Za-z0-9]/_}"
  printf '%s\t%s\n' "$slug" "$name" >> "$out/checks/order"
  if ( cd "$ROOT_DIR" && "$@" ) > "$out/checks/${slug}.log" 2>&1; then
    printf 'pass\n' > "$out/checks/${slug}.status"
  else
    printf 'fail\n' > "$out/checks/${slug}.status"
  fi
  printf '%s: %s\n' "$name" "$(cat "$out/checks/${slug}.status")"
}

cmd_skip() {
  local out="$1" name="$2" reason="$3"
  local slug="${name//[^A-Za-z0-9]/_}"
  printf '%s\t%s\n' "$slug" "$name" >> "$out/checks/order"
  printf 'skip\n' > "$out/checks/${slug}.status"
  printf '%s\n' "$reason" > "$out/checks/${slug}.log"
}

meta() {
  sed -n "s/^$2=//p" "$1/meta"
}

cmd_report() {
  local out="$1"
  local ref upstream_sha upstream_tag fork_sha ahead
  ref="$(meta "$out" ref)"
  upstream_sha="$(meta "$out" upstream_sha)"
  upstream_tag="$(meta "$out" upstream_tag)"
  fork_sha="$(meta "$out" fork_sha)"
  ahead="$(meta "$out" ahead)"
  local status conflicts=0 hunks=0 failed=0
  status="$(cat "$out/merge-status")"
  if [[ -s "$out/conflicts.tsv" ]]; then
    conflicts="$(wc -l < "$out/conflicts.tsv" | tr -d ' ')"
    hunks="$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$out/conflicts.tsv")"
  fi
  if [[ -f "$out/checks/order" ]]; then
    failed="$(cat "$out"/checks/*.status | grep -c '^fail$' || true)"
  fi

  local headline
  if [[ "$status" == up-to-date ]]; then
    headline="Up to date: fork \`main\` already contains \`${ref}\`"
  elif [[ "$status" == clean && "$failed" == 0 ]]; then
    headline="Clean pass"
  else
    headline="${conflicts} conflicting file(s), ${failed} failing check(s)"
  fi

  printf '## Merge rehearsal: %s\n\n' "$headline"
  printf -- '- Upstream: `%s` at `%s` (latest tag reachable: `%s`), %s commits not in fork `main`\n' \
    "$ref" "${upstream_sha:0:9}" "$upstream_tag" "$ahead"
  printf -- '- Fork `main`: `%s`\n' "${fork_sha:0:9}"
  printf -- '- Ran: %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    printf -- '- Run: %s/%s/actions/runs/%s\n' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  fi
  printf '\n'

  if [[ "$status" == conflicts ]]; then
    printf '### Conflicts: %s file(s), %s hunk(s)\n\n' "$conflicts" "$hunks"
    printf '| File | Kind | Hunks | Fork feature (allowlist) | Fork commits touching it |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    local path kind n feature commits
    while IFS=$'\t' read -r path kind n feature commits; do
      printf '| `%s` | %s | %s | %s | %s |\n' "$path" "$kind" "$n" "$feature" "${commits//;/<br>}"
    done < "$out/conflicts.tsv"
    printf '\nThe checks below ran with every conflict resolved to upstream'"'"'s side (runbook step 2), '
    printf 'so a failure points at fork code that has to be re-applied through its hook.\n\n'
  elif [[ "$status" == clean ]]; then
    printf '### Conflicts: none\n\n'
  fi

  if [[ -f "$out/checks/order" ]]; then
    printf '### Checks\n\n| Check | Result |\n| --- | --- |\n'
    local slug name result
    while IFS=$'\t' read -r slug name; do
      result="$(cat "$out/checks/${slug}.status")"
      if [[ "$result" == skip ]]; then
        result="skip: $(head -n 1 "$out/checks/${slug}.log")"
      fi
      printf '| %s | %s |\n' "$name" "$result"
    done < "$out/checks/order"
    printf '\n'
    while IFS=$'\t' read -r slug name; do
      [[ "$(cat "$out/checks/${slug}.status")" == fail ]] || continue
      printf '<details><summary>%s: last %s log lines</summary>\n\n```\n' "$name" "$LOG_TAIL_LINES"
      tail -n "$LOG_TAIL_LINES" "$out/checks/${slug}.log" | cut -c1-300 | sed 's/```/` ` `/g'
      printf '```\n</details>\n\n'
    done < "$out/checks/order"
  fi

  printf -- '---\n*Updated in place by the UsageBar merge rehearsal '
  printf '(`.github/workflows/usagebar-merge-rehearsal.yml`). It pushes nothing. '
  printf 'Merge procedure: `linux/upstream/RUNBOOK.md`.*\n'
}

case "${1:-}" in
  merge) [[ $# == 3 ]] || die "usage: merge <upstream-ref> <out-dir>"; cmd_merge "$2" "$3" ;;
  check) [[ $# -ge 4 ]] || die "usage: check <out-dir> <name> -- <command...>"; shift; cmd_check "$@" ;;
  skip) [[ $# == 4 ]] || die "usage: skip <out-dir> <name> <reason>"; cmd_skip "$2" "$3" "$4" ;;
  report) [[ $# == 2 ]] || die "usage: report <out-dir>"; cmd_report "$2" ;;
  *) die "usage: $(basename "$0") merge|check|skip|report ..." ;;
esac
