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

# Shutdown: stop launching, signal each recorded job. The RELIABLE mechanism is direct-child
# TERM then KILL + reap; an OPTIONAL best-effort process-group kill (kill -- -<pgid>) is also
# attempted, but is only meaningful where the launcher established job control before `&` (so
# pid == pgid). Where it isn't, the negative-pid kills simply no-op and the direct-child path
# still tears everything down. A grandchild that briefly survives can only write into the
# (about-to-be-removed) temp dir, so it cannot corrupt a fresh retry. Arrays are always
# initialized (see batch_run) so `${#arr[@]}` is never a bad substitution.
_batch_shutdown() {
  local p
  # Best-effort group TERM first (no-op where pid is not a real pgid).
  if [ "${#_BATCH_PGIDS[@]}" -gt 0 ]; then
    for p in "${_BATCH_PGIDS[@]}"; do
      [ -n "$p" ] && kill -TERM "-$p" 2>/dev/null || :
    done
  fi
  # Reliable direct-child TERM.
  if [ "${#_BATCH_PIDS[@]}" -gt 0 ]; then
    for p in "${_BATCH_PIDS[@]}"; do
      [ -n "$p" ] && kill -TERM "$p" 2>/dev/null || :
    done
  fi
  # Brief grace, then hard kill any survivors.
  local waited=0
  while [ "$waited" -lt 10 ]; do
    local alive=0
    if [ "${#_BATCH_PIDS[@]}" -gt 0 ]; then
      for p in "${_BATCH_PIDS[@]}"; do
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1
      done
    fi
    [ "$alive" -eq 0 ] && break
    sleep 0.1; waited=$((waited+1))
  done
  if [ "${#_BATCH_PGIDS[@]}" -gt 0 ]; then
    for p in "${_BATCH_PGIDS[@]}"; do [ -n "$p" ] && kill -KILL "-$p" 2>/dev/null || :; done
  fi
  if [ "${#_BATCH_PIDS[@]}" -gt 0 ]; then
    for p in "${_BATCH_PIDS[@]}";  do [ -n "$p" ] && kill -KILL "$p"  2>/dev/null || :; done
  fi
  wait 2>/dev/null || :
  # Explicitly close the token-bucket FIFO fd so no reader/writer keeps it open.
  exec 9>&- 2>/dev/null || :
  exec 9<&- 2>/dev/null || :
  [ -n "${_BATCH_TMP:-}" ] && rm -rf "$_BATCH_TMP"
  _BATCH_TMP=""
}

# _batch_on_signal: run cleanup, then exit nonzero — an interrupted batch must NOT fall
# through into normal aggregation.
_batch_on_signal() {
  _batch_shutdown
  trap - EXIT INT TERM
  exit 130
}

# batch_run: run the queue throttled, capture each job's stdout/stderr/rc to a temp
# dir, then emit per-job stdout in registration order + a === Summary === block.
# Errexit-safe: this library is SOURCED by wrappers running under `set -euo pipefail`.
# A reviewer tool returning nonzero is the EXPECTED error case, so each dispatch call
# and the `wait` are wrapped so errexit can never abort the batch.
batch_run() {
  _batch_validate_max_parallel || return 1

  _BATCH_PIDS=()
  _BATCH_PGIDS=()
  _BATCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-batch.XXXXXX")"
  # Install the cleanup trap IMMEDIATELY after the temp dir is created — BEFORE mkfifo /
  # `exec 9<>` — so that if any later setup step (mkfifo, fd open) fails, the EXIT trap
  # still removes the just-created temp dir instead of leaking it. EXIT runs cleanup on any
  # exit path; INT/TERM run cleanup then exit nonzero (no fall-through into aggregation).
  # The EXIT trap stays armed through aggregation so an interruption DURING aggregation
  # still removes the temp dir.
  trap '_batch_shutdown' EXIT
  trap '_batch_on_signal' INT TERM
  local tmp="$_BATCH_TMP" fifo="$_BATCH_TMP/tokens"
  mkfifo "$fifo"
  exec 9<>"$fifo"

  # Enable job control in the LAUNCHER shell so each `job &` below starts in its own process
  # group (its pid IS its pgid) — this is what makes the OPTIONAL group kill correct where
  # supported. On platforms where this is a no-op, the direct-child reap still tears down.
  set -m 2>/dev/null || true

  local t
  for ((t=0; t<MAX_PARALLEL; t++)); do printf '\n' >&9; done

  local i pid
  for i in "${!_BATCH_LABELS[@]}"; do
    read -r -u 9 _token
    (
      eval "set -- ${_BATCH_ARGV[$i]}"
      # The reviewer tool may exit nonzero (the expected ERROR case); capture its rc
      # explicitly so errexit cannot abort this job, write the rc file BEFORE returning
      # the token.
      set +e
      "$BATCH_DISPATCH_SH" "$@" > "$tmp/$i.out" 2> "$tmp/$i.err"
      _jrc=$?
      set -e
      printf '%s' "$_jrc" > "$tmp/$i.rc"
      printf '\n' >&9
    ) &
    pid=$!
    _BATCH_PIDS+=("$pid")
    # Candidate pgid: valid ONLY because the launcher enabled job control before `&` above,
    # so the job started as its own group leader (pid == pgid). Where job control is a
    # no-op the negative-pid signal simply fails harmlessly; the direct PID is reaped anyway.
    _BATCH_PGIDS+=("$pid")
  done
  # Re-disable launcher job control so the rest of batch_run runs normally. A child exiting
  # nonzero must not abort the batch under errexit.
  set +m 2>/dev/null || true
  wait || :
  exec 9>&-
  # All jobs have been reaped by `wait`. Clear the PID/PGID arrays BEFORE aggregation so that
  # if INT/TERM fires DURING aggregation (the trap stays armed), _batch_shutdown does not
  # signal already-reaped PIDs — which may have been reused by unrelated processes. The
  # temp-dir cleanup stays armed (EXIT is NOT disarmed); only the now-meaningless kill targets
  # are emptied.
  _BATCH_PIDS=()
  _BATCH_PGIDS=()
  # NOTE: do NOT disarm the EXIT trap here — cleanup must stay armed through aggregation so an
  # interruption during aggregation still removes the temp dir. INT/TERM are likewise left
  # armed; an interrupt during aggregation runs _batch_on_signal (cleanup + nonzero exit).

  local rc frag summary="" rc_all=0
  for i in "${!_BATCH_LABELS[@]}"; do
    rc="$(cat "$tmp/$i.rc" 2>/dev/null || printf '1')"
    printf '## %s\n' "${_BATCH_LABELS[$i]}"
    cat "$tmp/$i.out" 2>/dev/null
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

  # Success path: remove the temp dir and clear _BATCH_TMP so the still-armed EXIT trap's
  # cleanup is an idempotent no-op. Then disarm the traps and return.
  rm -rf "$tmp"
  _BATCH_TMP=""
  trap - EXIT INT TERM
  return "$rc_all"
}
