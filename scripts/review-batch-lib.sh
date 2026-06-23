#!/usr/bin/env bash
# Batch reviewer dispatch engine for the superpowers-codex plugin. SOURCED by the
# review-*.sh wrappers (never executed directly). Provides batch_init / batch_add /
# batch_run over the existing scripts/dispatch.sh (path read from BATCH_DISPATCH_SH).
#
# Portability: bash 3.2 / BSD-safe. No `wait -n`, no `sort -V`, no `setsid`, no `mapfile`.

# batch_init: reset the job queue and batch-level state.
batch_init() {
  _BATCH_LABELS=()
  _BATCH_ARGV=()           # each entry = one job's full argv, %q-encoded (subcommand + args)
  # Default to 5 only when MAX_PARALLEL is genuinely UNSET. An explicitly EMPTY value
  # (MAX_PARALLEL="") must survive to validation so it can fail fast — do NOT use
  # `: "${MAX_PARALLEL:=5}"`, which would silently rewrite "" to 5.
  if [ -z "${MAX_PARALLEL+x}" ]; then MAX_PARALLEL=5; fi
}

# batch_add <label> <subcommand> <dispatch-args...> : register one job.
# argv is %q-encoded so values containing whitespace/metachars round-trip intact.
batch_add() {
  local label="$1"; shift
  local enc="" a
  for a in "$@"; do
    enc="$enc $(printf '%q' "$a")"
  done
  _BATCH_LABELS+=("$label")
  _BATCH_ARGV+=("$enc")
}

# _batch_validate_max_parallel: default ONLY when unset (empty must fail), enforce
# ^[1-9][0-9]*$ (rejects empty, 0, leading-zero, non-numeric), clamp to the cap (16).
_BATCH_MAX_CAP=16
_batch_validate_max_parallel() {
  # Default to 5 only when MAX_PARALLEL is genuinely UNSET — an empty value is invalid.
  if [ -z "${MAX_PARALLEL+x}" ]; then MAX_PARALLEL=5; fi
  # Enforce ^[1-9][0-9]*$ without extglob: reject empty / non-digit, then leading zero.
  case "$MAX_PARALLEL" in
    ''|*[!0-9]*|0*) printf 'review-batch: --max-parallel must be a positive integer, got: %s\n' "${MAX_PARALLEL:-<empty>}" >&2; return 1 ;;
  esac
  if [ "$MAX_PARALLEL" -gt "$_BATCH_MAX_CAP" ]; then
    printf 'review-batch: --max-parallel %s exceeds cap %s; clamping to %s\n' "$MAX_PARALLEL" "$_BATCH_MAX_CAP" "$_BATCH_MAX_CAP" >&2
    MAX_PARALLEL="$_BATCH_MAX_CAP"
  fi
  return 0
}

# _batch_classify <out-file> <err-file> <rc> : print the Summary status fragment.
_batch_classify() {
  local out="$1" err="$2" rc="$3" verdict
  verdict="$(grep -E '^(Status|Verdict):' "$out" 2>/dev/null | tail -1)"
  if [ -n "$verdict" ]; then
    if [ "$rc" -ne 0 ]; then printf '%s (tool exit %s)' "$verdict" "$rc"
    else printf '%s' "$verdict"; fi
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'ERROR (tool failed, exit %s)' "$rc"
  else
    printf '(prose — 見全文)'
  fi
}

# batch_run: run the queue throttled, capture each job's stdout/stderr/rc to a temp
# dir, then emit per-job stdout in registration order + a === Summary === block.
# Errexit-safe: this library is SOURCED by wrappers running under `set -euo pipefail`.
# A reviewer tool returning nonzero is the EXPECTED error case, so each dispatch call
# and the `wait` are wrapped so errexit can never abort the batch.
batch_run() {
  _batch_validate_max_parallel || return 1

  local tmp fifo
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-batch.XXXXXX")"
  fifo="$tmp/tokens"
  mkfifo "$fifo"
  exec 9<>"$fifo"
  local t
  for ((t=0; t<MAX_PARALLEL; t++)); do printf '\n' >&9; done

  local i
  for i in "${!_BATCH_LABELS[@]}"; do
    read -r -u 9 _token
    (
      eval "set -- ${_BATCH_ARGV[$i]}"
      # The reviewer tool may exit nonzero (the expected ERROR case). Capture its rc
      # explicitly so errexit cannot abort this job, write the rc file BEFORE returning
      # the token, then return the token.
      set +e
      "$BATCH_DISPATCH_SH" "$@" > "$tmp/$i.out" 2> "$tmp/$i.err"
      _jrc=$?
      set -e
      printf '%s' "$_jrc" > "$tmp/$i.rc"
      printf '\n' >&9
    ) &
  done
  # A child exiting nonzero must not abort the batch under errexit.
  wait || :
  exec 9>&-

  # Aggregate in registration order.
  local rc frag summary="" rc_all=0
  for i in "${!_BATCH_LABELS[@]}"; do
    rc="$(cat "$tmp/$i.rc" 2>/dev/null || printf '1')"
    printf '## %s\n' "${_BATCH_LABELS[$i]}"
    cat "$tmp/$i.out" 2>/dev/null
    # For ERROR jobs (no verdict + nonzero), append a stderr excerpt to the section.
    if ! grep -Eq '^(Status|Verdict):' "$tmp/$i.out" 2>/dev/null && [ "$rc" -ne 0 ]; then
      printf '\n[stderr excerpt]\n'
      tail -20 "$tmp/$i.err" 2>/dev/null
      rc_all=1
    fi
    printf '\n'
    frag="$(_batch_classify "$tmp/$i.out" "$tmp/$i.err" "$rc")"
    summary="$summary- ${_BATCH_LABELS[$i]}: $frag
"
  done
  printf '=== Summary ===\n'
  printf '%s' "$summary"

  rm -rf "$tmp"
  return "$rc_all"
}
