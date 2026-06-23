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

# batch_run: run the queue with a FIFO token-bucket so at most MAX_PARALLEL jobs run
# concurrently. Preload N tokens into a FIFO; each job reads one before starting and
# writes one back on finish. Works on bash 3.2 (no `wait -n`).
batch_run() {
  _batch_validate_max_parallel || return 1

  local fifo_dir fifo
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/review-batch.XXXXXX")"
  fifo="$fifo_dir/tokens"
  mkfifo "$fifo"
  # Open the FIFO read+write on fd 9 so writes don't block on a reader and the bucket
  # persists for the whole run.
  exec 9<>"$fifo"
  local t
  for ((t=0; t<MAX_PARALLEL; t++)); do printf '\n' >&9; done

  local i
  for i in "${!_BATCH_LABELS[@]}"; do
    # Block until a token is available, then launch the job in the background.
    read -r -u 9 _token
    (
      eval "set -- ${_BATCH_ARGV[$i]}"
      "$BATCH_DISPATCH_SH" "$@"
      printf '\n' >&9    # return the token on finish
    ) &
  done
  wait

  exec 9>&-
  rm -rf "$fifo_dir"
}
