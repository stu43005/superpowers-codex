#!/usr/bin/env bash
# Shared reviewer dispatch for the superpowers-codex plugin.
# Subcommands: task | review | adversarial
set -euo pipefail

# Pinned minimum codex companion version (calibrated to installed 1.0.4).
# The companion exposes no version command; version is read from its install path.
# Override the resolved companion for tests with DISPATCH_COMPANION.
MIN_COMPANION_VERSION="1.0.4"

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dispatch-prompt-lib.sh"

# --- pure-bash version compare (no `sort -V`; portable to bash 3.2 / BSD) ---
# ver_ge A B  -> exit 0 iff dotted-numeric A >= B
ver_ge() {
  local -a A B; local i n x y
  IFS=. read -ra A <<< "$1"; IFS=. read -ra B <<< "$2"   # split on dots (ShellCheck-clean)
  n=${#A[@]}; [ "${#B[@]}" -gt "$n" ] && n=${#B[@]}
  for ((i=0; i<n; i++)); do
    x=${A[i]:-0}; y=${B[i]:-0}
    x=${x//[!0-9]/}; y=${y//[!0-9]/}      # drop any pre-release suffix chars
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    ((x>y)) && return 0
    ((x<y)) && return 1
  done
  return 0
}

# --- companion resolution (no `ls|sort -V`; pick max version in pure bash) ---
# Prints the resolved companion path, or "" if none found. Honors DISPATCH_COMPANION.
resolve_companion() {
  if [ -n "${DISPATCH_COMPANION:-}" ]; then printf '%s' "$DISPATCH_COMPANION"; return 0; fi
  local best="" best_ver="" c v
  for c in "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs; do
    [ -f "$c" ] || continue                 # unmatched glob stays literal -> skipped
    v="${c#*/codex/}"; v="${v%%/*}"
    if [ -z "$best" ] || ver_ge "$v" "$best_ver"; then best="$c"; best_ver="$v"; fi
  done
  if [ -z "$best" ]; then
    local fb="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
    [ -f "$fb" ] && best="$fb"
  fi
  printf '%s' "$best"
}
require_companion() {                       # prints path or dies
  local c; c="$(resolve_companion)"
  [ -n "$c" ] || die "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review."
  printf '%s' "$c"
}

# --- version guard: read version from the .../codex/<ver>/scripts/... path segment ---
check_companion_version() {
  local companion="$1" ver=""
  case "$companion" in
    */codex/*/scripts/codex-companion.mjs)
      ver="${companion#*/codex/}"; ver="${ver%%/*}" ;;
  esac
  case "$ver" in
    [0-9]*)                                 # versioned cache path -> assert minimum
      ver_ge "$ver" "$MIN_COMPANION_VERSION" || \
        die "codex companion $ver < required $MIN_COMPANION_VERSION; run /codex:setup to update codex." ;;
    *)                                      # version cannot be derived (e.g. the un-versioned
      # marketplace fallback path): hard stop — never run an unverifiable companion. Resolution
      # still keeps the fallback path, but the user must run /codex:setup for a versioned copy.
      die "cannot determine codex companion version from ($companion); run /codex:setup to install a versioned codex." ;;
  esac
}

# Run the codex companion, dropping its '[codex] ' progress lines (the companion writes those
# to stderr; see tracked-jobs.mjs) — the agent only needs the reviewer result, not the noise.
# stdout (the reviewer result) is left untouched and streamed; genuine non-'[codex]' stderr is
# preserved; the companion's own exit code is propagated (NOT grep's).
run_companion() {
  local rc
  set +e
  # fd3 = caller stdout. The companion's stdout -> fd3 (untouched); its stderr -> the pipe ->
  # grep -> stderr. grep exiting 1 (everything filtered) must not mask the companion's status,
  # so read it from PIPESTATUS[0].
  { "$@" 2>&1 1>&3 | grep -v '^\[codex\] ' >&2; } 3>&1
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

cmd_task() {
  task_assemble_prompt "$@"
  local work="$REPLY" dry="$TASK_DRY_RUN"

  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    printf -- '--- DRY RUN: command ---\n'
    printf 'node %q task --prompt-file %q\n' "${c:-<companion-unresolved>}" "$work"
    printf -- '--- DRY RUN: prompt ---\n'
    cat "$work"
    return 0
  fi
  local companion; companion="$(require_companion)"
  check_companion_version "$companion"
  # Runs in the foreground (no '&', no detach flag) so temp files outlive the reviewer.
  run_companion node "$companion" task --prompt-file "$work"
}

cmd_review() {
  local base="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "review: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "review: --base is required"
  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    printf 'node %q review --base %q --wait\n' "${c:-<companion-unresolved>}" "$base"; return 0
  fi
  local companion; companion="$(require_companion)"; check_companion_version "$companion"
  run_companion node "$companion" review --base "$base" --wait
}

cmd_adversarial() {
  local base="" focus="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --focus) focus="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "adversarial: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "adversarial: --base is required"
  [ -n "$focus" ] || die "adversarial: --focus is required"
  require_file "$focus"
  local focus_text; focus_text="$(cat "$focus")"
  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    # focus is a trailing POSITIONAL; --wait is a boolean flag.
    printf 'node %q adversarial-review --base %q --wait %q\n' "${c:-<companion-unresolved>}" "$base" "$focus_text"; return 0
  fi
  local companion; companion="$(require_companion)"; check_companion_version "$companion"
  run_companion node "$companion" adversarial-review --base "$base" --wait "$focus_text"
}

main() {
  [ $# -ge 1 ] || die "usage: dispatch.sh {task|review|adversarial} ..."
  local sub="$1"; shift
  case "$sub" in
    task)        cmd_task "$@" ;;
    review)      cmd_review "$@" ;;
    adversarial) cmd_adversarial "$@" ;;
    *) die "unknown subcommand: $sub (expected task|review|adversarial)" ;;
  esac
}
main "$@"
