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

# batch_run: execute the queue sequentially through BATCH_DISPATCH_SH and stream
# each job's stdout. (Throttling, capture, and aggregation are layered on later.)
batch_run() {
  local i
  for i in "${!_BATCH_LABELS[@]}"; do
    eval "set -- ${_BATCH_ARGV[$i]}"
    "$BATCH_DISPATCH_SH" "$@"
  done
}
