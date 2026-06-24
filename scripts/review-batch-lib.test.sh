#!/usr/bin/env bash
# Plain-bash tests for review-batch-lib.sh and the three wrappers. Hermetic:
# dispatch.sh is replaced by a stub injected via BATCH_DISPATCH_SH; PLUGIN_ROOT is
# overridden to a fixture dir. No live codex / network is ever invoked.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/review-batch-lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

# write_stub <file> <body-lines...> : create an executable stub dispatch.sh.
write_stub() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$f"
  chmod +x "$f"
}

# A stub that echoes its own argv, one arg per line prefixed with "ARG:".
ECHO_STUB="$ROOT/echo/dispatch.sh"
write_stub "$ECHO_STUB" 'for a in "$@"; do printf "ARG:%s\n" "$a"; done'

# argv round-trip: a value containing a space survives intact through %q encoding.
( set -e
  BATCH_DISPATCH_SH="$ECHO_STUB"
  . "$LIB"
  batch_init
  batch_add "only" task --prompt /tmp/p.md --set "TASK_ID=Task 1"
  OUT="$(batch_run 2>/dev/null)"; printf '%s' "$OUT"
) > "$ROOT/t1.out" 2>/dev/null
T1="$(cat "$ROOT/t1.out")"
if printf '%s' "$T1" | grep -qx 'ARG:task' \
   && printf '%s' "$T1" | grep -qx 'ARG:--prompt' \
   && printf '%s' "$T1" | grep -qx 'ARG:/tmp/p.md' \
   && printf '%s' "$T1" | grep -qx 'ARG:--set' \
   && printf '%s' "$T1" | grep -qx 'ARG:TASK_ID=Task 1'; then
  ok "argv round-trip: space-containing --set value not split"
else
  bad "argv round-trip: space-containing --set value not split" "$T1"
fi

# Empty, zero, leading-zero (0*, e.g. 01/03), and non-numeric --max-parallel values all
# fail fast. MAX_PARALLEL is set BEFORE batch_init so an explicit "" survives (batch_init
# only defaults when UNSET) and reaches validation.
for bad_mp in 0 "" abc 3x 03; do
  ( BATCH_DISPATCH_SH="$ECHO_STUB"; . "$LIB"; MAX_PARALLEL="$bad_mp"; batch_init
    batch_add j task --base HEAD; batch_run ) >/dev/null 2>&1
  if [ "$?" -ne 0 ]; then ok "invalid --max-parallel '$bad_mp' fails fast"
  else bad "invalid --max-parallel '$bad_mp' fails fast" "rc=0"; fi
done

# A huge, all-digit but out-of-range --max-parallel must NOT bypass the cap. The `-gt` numeric
# comparison errors ("integer expression expected") on values beyond the shell integer range; if
# that error is treated as "not greater" the value stays huge and the token-fill loop hangs. It
# must clamp to the cap like any other over-cap value (16), validated by reading MAX_PARALLEL back.
HUGE_MP="$( . "$LIB"; MAX_PARALLEL="999999999999999999999"
  _batch_validate_max_parallel 2>/dev/null; printf '%s' "$MAX_PARALLEL" )"
[ "$HUGE_MP" = "16" ] && ok "huge --max-parallel clamps to cap (no out-of-range bypass)" \
  || bad "huge --max-parallel clamps to cap" "got=$HUGE_MP"

# Peak concurrency reaches exactly the cap and never exceeds it.
# The stub appends "+" on start and "-" on finish to a shared file, with a short sleep,
# so a post-hoc scan of the running count reveals the true peak.
CONC_LOG="$ROOT/conc.log"
CONC_STUB="$ROOT/conc/dispatch.sh"
write_stub "$CONC_STUB" \
  'echo "+" >> "'"$CONC_LOG"'"' \
  'sleep 0.3' \
  'echo "-" >> "'"$CONC_LOG"'"' \
  'echo "Status: OKAY"'
: > "$CONC_LOG"
( BATCH_DISPATCH_SH="$CONC_STUB"; . "$LIB"; MAX_PARALLEL=2; batch_init
  i=0; while [ "$i" -lt 6 ]; do batch_add "j$i" task --base HEAD; i=$((i+1)); done
  batch_run ) >/dev/null 2>&1
peak=0; cur=0
while IFS= read -r line; do
  case "$line" in
    "+") cur=$((cur+1)); [ "$cur" -gt "$peak" ] && peak=$cur ;;
    "-") cur=$((cur-1)) ;;
  esac
done < "$CONC_LOG"
[ "$peak" -eq 2 ] \
  && ok "peak concurrency reaches exactly MAX_PARALLEL (peak=$peak)" \
  || bad "peak concurrency reaches exactly MAX_PARALLEL" "peak=$peak"

# stdout aggregation, four-way classification, and registration-order headings.
OKAY_STUB="$ROOT/okay/dispatch.sh"
write_stub "$OKAY_STUB" 'echo "looks complete"' 'echo "Status: OKAY"'
ISSUES_STUB="$ROOT/issues/dispatch.sh"
write_stub "$ISSUES_STUB" 'echo "found a gap"' 'echo "Status: Issues Found"'
ERR_STUB="$ROOT/err/dispatch.sh"
write_stub "$ERR_STUB" 'echo "partial work" ' 'echo "boom on stderr" >&2' 'exit 2'
PROSE_STUB="$ROOT/prose/dispatch.sh"
write_stub "$PROSE_STUB" 'echo "free-form prose, no verdict line"'

# Build a mixed batch by switching BATCH_DISPATCH_SH per job is not possible (one path),
# so register four jobs against ONE multiplexer stub keyed by the label-derived first arg.
MUX_STUB="$ROOT/mux/dispatch.sh"
write_stub "$MUX_STUB" \
  'case "$1" in' \
  '  okay)   echo "looks complete"; echo "Status: OKAY" ;;' \
  '  issues) echo "found a gap"; echo "Status: Issues Found" ;;' \
  '  err)    echo "partial work"; echo "boom on stderr" >&2; exit 2 ;;' \
  '  prose)  echo "free-form prose, no verdict line" ;;' \
  'esac'

T3="$( BATCH_DISPATCH_SH="$MUX_STUB"; . "$LIB"; MAX_PARALLEL=4; batch_init
  batch_add "A-okay"   okay
  batch_add "B-issues" issues
  batch_add "C-err"    err
  batch_add "D-prose"  prose
  batch_run 2>/dev/null )"

# headings present and in registration order
order="$(printf '%s\n' "$T3" | grep -n '^## ' | sed 's/:.*//' | tr '\n' ' ')"
hA="$(printf '%s\n' "$T3" | grep -n '^## A-okay$'   | head -1 | sed 's/:.*//')"
hB="$(printf '%s\n' "$T3" | grep -n '^## B-issues$' | head -1 | sed 's/:.*//')"
hC="$(printf '%s\n' "$T3" | grep -n '^## C-err$'    | head -1 | sed 's/:.*//')"
hD="$(printf '%s\n' "$T3" | grep -n '^## D-prose$'  | head -1 | sed 's/:.*//')"
if [ -n "$hA" ] && [ "$hA" -lt "$hB" ] && [ "$hB" -lt "$hC" ] && [ "$hC" -lt "$hD" ]; then
  ok "headings emitted in registration order"
else bad "headings emitted in registration order" "order=$order"; fi

# Summary classification lines
SUM="$(printf '%s\n' "$T3" | sed -n '/^=== Summary ===$/,$p')"
printf '%s\n' "$SUM" | grep -q 'A-okay:.*Status: OKAY' \
  && ok "okay job classified OKAY" || bad "okay job classified OKAY" "$SUM"
printf '%s\n' "$SUM" | grep -q 'B-issues:.*Status: Issues Found' \
  && ok "issues job classified Issues Found" || bad "issues job classified Issues Found" "$SUM"
printf '%s\n' "$SUM" | grep -q 'C-err:.*ERROR (tool failed, exit 2)' \
  && ok "no-verdict + nonzero classified ERROR" || bad "no-verdict + nonzero classified ERROR" "$SUM"
printf '%s\n' "$SUM" | grep -q 'D-prose:.*prose' \
  && ok "prose job classified prose" || bad "prose job classified prose" "$SUM"

# stderr excerpt of the ERROR job is appended to its section
printf '%s\n' "$T3" | grep -q 'boom on stderr' \
  && ok "ERROR job stderr excerpt appended" || bad "ERROR job stderr excerpt appended" "$T3"

# Errexit safety: source the library from a `set -euo pipefail` shell and run a job
# whose tool exits nonzero with no verdict line. A reviewer tool failing is the EXPECTED
# error case, so neither the job's nonzero exit nor the nonzero `wait` may abort the batch
# under errexit: the Summary must still be emitted and the batch must not hang. Reaching
# the assertion at all (the subshell returns, not aborts) proves no deadlock/abort.
EE_OUT="$ROOT/ee.out"
( set -euo pipefail
  BATCH_DISPATCH_SH="$MUX_STUB"
  . "$LIB"
  batch_init
  batch_add "E-err" err
  batch_run > "$EE_OUT" 2>/dev/null
) ; EE_RC=$?
if grep -q '^=== Summary ===$' "$EE_OUT"; then
  ok "errexit: Summary still emitted under set -e with a nonzero no-verdict job"
else bad "errexit: Summary still emitted under set -e with a nonzero no-verdict job" "$(cat "$EE_OUT")"; fi
printf '%s\n' "$EE_RC" | grep -qx '[0-9][0-9]*' \
  && ok "errexit: batch completes (returns a value, does not abort) under set -e" \
  || bad "errexit: batch completes under set -e" "rc=$EE_RC"

# Exit-code semantics: capture the batch rc into a variable BEFORE the assertion so a
# failure message shows the real rc (a bare $? inside [ ... ] would re-read the test's rc).
# All jobs produce a verdict (one is Issues Found) -> batch exits 0.
( BATCH_DISPATCH_SH="$MUX_STUB"; . "$LIB"; MAX_PARALLEL=4; batch_init
  batch_add "A-okay"   okay
  batch_add "B-issues" issues
  batch_run ) >/dev/null 2>&1
RC_ALLVERDICT=$?
[ "$RC_ALLVERDICT" -eq 0 ] && ok "all-verdict batch (incl Issues Found) exits 0" \
  || bad "all-verdict batch exits 0" "rc=$RC_ALLVERDICT"

# One job is ERROR (no verdict + nonzero) -> batch exits nonzero.
( BATCH_DISPATCH_SH="$MUX_STUB"; . "$LIB"; MAX_PARALLEL=4; batch_init
  batch_add "A-okay" okay
  batch_add "C-err"  err
  batch_run ) >/dev/null 2>&1
RC_ERR=$?
[ "$RC_ERR" -ne 0 ] && ok "batch with an ERROR job exits nonzero" \
  || bad "batch with an ERROR job exits nonzero" "rc=$RC_ERR"

# Errexit: the same ERROR case sourced under `set -euo pipefail` returns nonzero (does not
# abort early) — proving the ERROR exit code survives the errexit-safe wait/return path.
( set -euo pipefail
  BATCH_DISPATCH_SH="$MUX_STUB"
  . "$LIB"
  batch_init
  batch_add "C-err" err
  batch_run >/dev/null 2>&1
) ; RC_ERR_EE=$?
[ "$RC_ERR_EE" -ne 0 ] \
  && ok "errexit: ERROR batch returns nonzero under set -e" \
  || bad "errexit: ERROR batch returns nonzero under set -e" "rc=$RC_ERR_EE"

# A job that emits a verdict THEN exits nonzero (e.g. a teardown/streaming crash) is a tool
# failure (dispatch.sh exits nonzero only on a real tool error, never to signal findings). The
# engine must: keep the verdict and annotate it "(tool exit N)", show the stderr excerpt so the
# caller can judge whether the output is incomplete, and set the batch's nonzero exit.
VEXIT_STUB="$ROOT/vexit/dispatch.sh"
write_stub "$VEXIT_STUB" 'echo "Verdict: approve"' 'echo "late boom on stderr" >&2' 'exit 3'
TVE="$( BATCH_DISPATCH_SH="$VEXIT_STUB"; . "$LIB"; MAX_PARALLEL=2; batch_init
  batch_add "V-exit" ; batch_run 2>/dev/null )"
printf '%s\n' "$TVE" | sed -n '/^=== Summary ===$/,$p' | grep -q 'V-exit:.*Verdict: approve (tool exit 3)' \
  && ok "verdict + nonzero keeps verdict, annotates (tool exit N)" \
  || bad "verdict + nonzero keeps verdict, annotates (tool exit N)" "$TVE"
printf '%s\n' "$TVE" | grep -q 'late boom on stderr' \
  && ok "verdict + nonzero shows stderr excerpt (caller can judge incompleteness)" \
  || bad "verdict + nonzero shows stderr excerpt" "$TVE"
( BATCH_DISPATCH_SH="$VEXIT_STUB"; . "$LIB"; MAX_PARALLEL=2; batch_init
  batch_add "V-exit" ; batch_run ) >/dev/null 2>&1
RC_VEXIT=$?
[ "$RC_VEXIT" -ne 0 ] && ok "verdict + nonzero marks batch nonzero (tool failure surfaced)" \
  || bad "verdict + nonzero marks batch nonzero" "rc=$RC_VEXIT"

# _batch_classify must be errexit-safe even when called DIRECTLY (not via command substitution)
# under `set -euo pipefail`. A prose-only stdout (no Status/Verdict line) makes the internal grep
# exit 1; under pipefail the no-match must NOT abort the function before it prints the prose
# classification. (batch_run currently shields this by calling _batch_classify via $(...), where
# errexit is not inherited — but the function must be robust on its own so the contract does not
# depend on that call shape.)
printf 'free-form prose, no verdict line\n' > "$ROOT/prose.in"
PC_OUT="$ROOT/prose-classify.out"
( set -euo pipefail
  . "$LIB"
  _batch_classify "$ROOT/prose.in" /dev/null 0 > "$PC_OUT"
) ; PC_RC=$?
if [ "$PC_RC" -eq 0 ] && grep -q 'prose — 見全文' "$PC_OUT"; then
  ok "_batch_classify errexit-safe on prose-only input (direct call under set -euo pipefail)"
else bad "_batch_classify errexit-safe on prose-only input" "rc=$PC_RC out=$(cat "$PC_OUT" 2>/dev/null)"; fi

# A normal run leaves no review-batch.* temp dir behind, and writes nothing under the
# project/repo dir (no .claude/superpowers/review is ever created).
before_dirs="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
PROJDIR="$ROOT/proj"; mkdir -p "$PROJDIR"
( cd "$PROJDIR"
  BATCH_DISPATCH_SH="$OKAY_STUB"; . "$LIB"; MAX_PARALLEL=2; batch_init
  batch_add "A" ; batch_add "B"
  batch_run ) >/dev/null 2>&1
after_dirs="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$after_dirs" -le "$before_dirs" ] \
  && ok "temp dir removed after normal run" \
  || bad "temp dir removed after normal run" "before=$before_dirs after=$after_dirs"
[ ! -e "$PROJDIR/.claude/superpowers/review" ] && [ -z "$(ls -A "$PROJDIR" 2>/dev/null)" ] \
  && ok "run writes nothing under the project dir" \
  || bad "run writes nothing under the project dir" "$(ls -A "$PROJDIR" 2>/dev/null)"

# Grandchild isolation under INT (the RELIABLE guarantee — asserted on every platform).
# A stub spawns a grandchild that, after a delay, writes a marker into a batch-owned path:
# GC_MARK_DIR points at the live run's temp dir, resolved at runtime by globbing the single
# review-batch.* dir present during this run. So the grandchild's marker, if it writes one,
# lands INSIDE the batch temp dir. The reliable guarantee, independent of whether the
# grandchild is killed, is: the run's temp dir is `rm -rf`-ed on INT, so the marker location
# itself is removed and a fresh retry (a brand-new temp dir) can never observe it. The
# assertion below actually reads the marker location and confirms it is gone after cleanup —
# whether because the grandchild was killed (strong path) or because the dir holding it was
# removed (weak fallback). We do NOT require the grandchild to have been killed here (that
# needs process-group support — covered separately below).
GC_STUB="$ROOT/gc/dispatch.sh"
write_stub "$GC_STUB" \
  '# Resolve the live batch temp dir at runtime (the only review-batch.* dir during this run)' \
  'gc_dir="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | head -1)"' \
  ': "${GC_MARK_DIR:=$gc_dir}"' \
  '( sleep 1; echo "GRANDCHILD-MARKER" >> "${GC_MARK_DIR:-/tmp}/gc-marker" 2>/dev/null ) &' \
  'sleep 2' \
  'echo "Status: OKAY"'
gc_before="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
( BATCH_DISPATCH_SH="$GC_STUB"; . "$LIB"; MAX_PARALLEL=1; batch_init
  batch_add "slow" task --prompt /tmp/p.md
  batch_run ) >/dev/null 2>&1 &
BATCH_PID=$!
# Capture the live run's temp dir (the only review-batch.* dir) while the slow job runs, so the
# assertion can read the exact marker location the grandchild targets.
sleep 0.4
GC_RUN_DIR="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | head -1)"
kill -INT "$BATCH_PID" 2>/dev/null
wait "$BATCH_PID" 2>/dev/null
sleep 1.2   # past the grandchild's 1s timer
gc_after="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$gc_after" -le "$gc_before" ] \
  && ok "INT removes the run's temp dir (stale grandchild output can only land in it)" \
  || bad "INT removes the run's temp dir" "before=$gc_before after=$gc_after"
# Read the marker location directly: after cleanup the batch temp dir is gone, so the marker the
# grandchild targeted (inside that dir) is absent — either it was killed before writing (strong)
# or the dir holding it was removed (weak fallback). Both satisfy the reliable guarantee.
if [ -n "$GC_RUN_DIR" ] && [ ! -e "$GC_RUN_DIR/gc-marker" ]; then
  ok "grandchild marker absent after INT (killed, or its batch temp dir was removed)"
else
  bad "grandchild marker absent after INT" "GC_RUN_DIR=$GC_RUN_DIR exists=$([ -e "$GC_RUN_DIR/gc-marker" ] && echo yes || echo no)"
fi
# A fresh retry after the INT runs cleanly into its own brand-new temp dir, unaffected by any
# stale grandchild (this proves the reliable no-cross-contamination guarantee).
RETRY="$( BATCH_DISPATCH_SH="$OKAY_STUB"; . "$LIB"; MAX_PARALLEL=1; batch_init
  batch_add "retry" ; batch_run 2>/dev/null )"
printf '%s\n' "$RETRY" | grep -q '^=== Summary ===$' \
  && ok "fresh retry after INT is unaffected by any stale grandchild" \
  || bad "fresh retry after INT is unaffected" "$RETRY"

# OPTIONAL process-group enhancement — DIAGNOSTIC ONLY (this assertion never reports `bad`,
# so it always contributes exactly one `ok` and the pass/fail count is deterministic).
# Whether a backgrounded job can be placed in its own process group depends on the platform's
# job-control behavior, which differs between a foreground probe and the backgrounded launcher
# the batch actually uses — so we never gate pass/fail on it. The RELIABLE guarantee (temp-dir
# removal + isolation, asserted above) is what matters; the grandchild-kill is reported for info.
PG_SUPPORTED=0
( set -m 2>/dev/null
  ( sleep 5 ) &
  _bgpid=$!
  # If job control set up a distinct process group, the bg pid is usable as a pgid for
  # `kill -- -<pid>`. Probe with signal 0 against the negative pgid.
  if kill -0 -- "-$_bgpid" 2>/dev/null; then exit 0; else exit 1; fi
  ) && PG_SUPPORTED=1 || PG_SUPPORTED=0
# clean up the probe's background sleep regardless
wait 2>/dev/null || :
if [ "$PG_SUPPORTED" -eq 1 ]; then
  GC_MARK="$ROOT/gc-mark-dir"; mkdir -p "$GC_MARK"; : > "$GC_MARK/gc-marker"
  ( BATCH_DISPATCH_SH="$GC_STUB"; GC_MARK_DIR="$GC_MARK"; export GC_MARK_DIR
    . "$LIB"; MAX_PARALLEL=1; batch_init
    batch_add "slow" task --prompt /tmp/p.md
    batch_run ) >/dev/null 2>&1 &
  PG_PID=$!
  sleep 0.4
  kill -INT "$PG_PID" 2>/dev/null
  wait "$PG_PID" 2>/dev/null
  sleep 1.2   # past the grandchild's 1s timer
  if ! grep -q 'GRANDCHILD-MARKER' "$GC_MARK/gc-marker" 2>/dev/null; then
    ok "diagnostic: process-group kill removed the grandchild"
  else
    ok "diagnostic: process-group kill unavailable here; reliable temp-dir isolation still holds"
  fi
else
  ok "diagnostic: process-group kill not probed; reliable temp-dir isolation suffices"
fi

# TERM (alongside INT) also reaps and removes the run's temp dir.
term_before="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
( BATCH_DISPATCH_SH="$GC_STUB"; . "$LIB"; MAX_PARALLEL=1; batch_init
  batch_add "slow" task --prompt /tmp/p.md
  batch_run ) >/dev/null 2>&1 &
TERM_PID=$!
sleep 0.4
kill -TERM "$TERM_PID" 2>/dev/null
wait "$TERM_PID" 2>/dev/null
sleep 1.2
term_after="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$term_after" -le "$term_before" ] \
  && ok "TERM removes the run's temp dir" \
  || bad "TERM removes the run's temp dir" "before=$term_before after=$term_after"

# review-brainstorm.sh assembles the two reviewers' dispatch argv from its CLI.
BRAINSTORM="$HERE/review-brainstorm.sh"
PROOT="$ROOT/plugin"   # fixture plugin root
mkdir -p "$PROOT/skills/brainstorming"
: > "$PROOT/skills/brainstorming/spec-document-reviewer-prompt.md"
: > "$PROOT/skills/brainstorming/adversarial-spec-review-focus.md"
T6="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
       bash "$BRAINSTORM" --spec docs/specs/x-design.md --base SPECBASE 2>/dev/null )"
# structural-completeness: task --prompt <root>/.../spec-document-reviewer-prompt.md --set SPEC_FILE_PATH=<spec>
if printf '%s\n' "$T6" | grep -q '^## structural-completeness$' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:task' \
   && printf '%s\n' "$T6" | grep -qx "ARG:--prompt" \
   && printf '%s\n' "$T6" | grep -qx "ARG:$PROOT/skills/brainstorming/spec-document-reviewer-prompt.md" \
   && printf '%s\n' "$T6" | grep -qx 'ARG:SPEC_FILE_PATH=docs/specs/x-design.md'; then
  ok "review-brainstorm: structural-completeness argv matches expected wrapper contract"
else bad "review-brainstorm: structural-completeness argv" "$T6"; fi
# design-soundness: adversarial --base <SPEC_BASE> --focus <root>/.../adversarial-spec-review-focus.md
if printf '%s\n' "$T6" | grep -q '^## design-soundness$' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:adversarial' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:--base' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:SPECBASE' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:--focus' \
   && printf '%s\n' "$T6" | grep -qx "ARG:$PROOT/skills/brainstorming/adversarial-spec-review-focus.md"; then
  ok "review-brainstorm: design-soundness argv matches expected wrapper contract"
else bad "review-brainstorm: design-soundness argv" "$T6"; fi

# review-plan.sh assembles per-Task (+ optional coverage) dispatch argv from its CLI.
PLAN_W="$HERE/review-plan.sh"
PROOT="${PROOT:-$ROOT/plugin}"   # fixture plugin root (defined locally; do not rely on it being set elsewhere)
mkdir -p "$PROOT/skills/writing-plans"
: > "$PROOT/skills/writing-plans/plan-document-reviewer-prompt.md"
: > "$PROOT/skills/writing-plans/coverage-verifier-prompt.md"
T7="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
       bash "$PLAN_W" --plan docs/plans/x.md --spec docs/specs/x.md \
         --task "Task 1" --task "Task 3" --coverage 2>/dev/null )"
# per-task Task 1 job: label + TASK_ID with a space intact
if printf '%s\n' "$T7" | grep -q '^## per-task Task 1$' \
   && printf '%s\n' "$T7" | grep -qx "ARG:--prompt" \
   && printf '%s\n' "$T7" | grep -qx "ARG:$PROOT/skills/writing-plans/plan-document-reviewer-prompt.md" \
   && printf '%s\n' "$T7" | grep -qx 'ARG:PLAN_FILE_PATH=docs/plans/x.md' \
   && printf '%s\n' "$T7" | grep -qx 'ARG:SPEC_FILE_PATH=docs/specs/x.md' \
   && printf '%s\n' "$T7" | grep -qx 'ARG:TASK_ID=Task 1'; then
  ok "review-plan: per-task Task 1 argv matches expected wrapper contract"
else bad "review-plan: per-task Task 1 argv" "$T7"; fi
printf '%s\n' "$T7" | grep -q '^## per-task Task 3$' \
  && ok "review-plan: second per-task job registered" \
  || bad "review-plan: second per-task job registered" "$T7"
# coverage-verifier job
if printf '%s\n' "$T7" | grep -q '^## coverage-verifier$' \
   && printf '%s\n' "$T7" | grep -qx "ARG:$PROOT/skills/writing-plans/coverage-verifier-prompt.md"; then
  ok "review-plan: coverage-verifier argv matches expected wrapper contract"
else bad "review-plan: coverage-verifier argv" "$T7"; fi
# require at least one --task or --coverage
( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
  bash "$PLAN_W" --plan docs/plans/x.md --spec docs/specs/x.md ) >/dev/null 2>&1
RC_REQ=$?
[ "$RC_REQ" -ne 0 ] && ok "review-plan: no --task/--coverage fails fast" \
  || bad "review-plan: no --task/--coverage fails fast" "rc=$RC_REQ"
# malformed CLI: a trailing option with no value fails with a clear wrapper error, NOT a
# raw `set -u` unbound-variable crash.
PLAN_ERR="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
  bash "$PLAN_W" --spec docs/specs/x.md --task "Task 1" --plan 2>&1 )"
RC_MALFORMED=$?
if [ "$RC_MALFORMED" -ne 0 ] \
   && printf '%s\n' "$PLAN_ERR" | grep -q 'review-plan: --plan requires a value' \
   && ! printf '%s\n' "$PLAN_ERR" | grep -qi 'unbound variable'; then
  ok "review-plan: missing option value fails with a clear wrapper error"
else bad "review-plan: missing option value fails with a clear wrapper error" "rc=$RC_MALFORMED out=$PLAN_ERR"; fi

# review-impl.sh assembles the spec-compliance + code-quality dispatch argv (no report file).
IMPL_W="$HERE/review-impl.sh"
PROOT="${PROOT:-$ROOT/plugin}"   # fixture plugin root (defined locally)
mkdir -p "$PROOT/skills/subagent-driven-development"
: > "$PROOT/skills/subagent-driven-development/spec-reviewer-prompt.md"
T8="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
       bash "$IMPL_W" --plan docs/plans/x.md --task "Task 2" --task-base TBASE 2>/dev/null )"
# spec-compliance: task --prompt <root>/.../spec-reviewer-prompt.md --set PLAN_FILE_PATH --set TASK_ID --set TASK_BASE
if printf '%s\n' "$T8" | grep -q '^## spec-compliance$' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:task' \
   && printf '%s\n' "$T8" | grep -qx "ARG:$PROOT/skills/subagent-driven-development/spec-reviewer-prompt.md" \
   && printf '%s\n' "$T8" | grep -qx 'ARG:PLAN_FILE_PATH=docs/plans/x.md' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:TASK_ID=Task 2' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:TASK_BASE=TBASE'; then
  ok "review-impl: spec-compliance argv matches expected wrapper contract"
else bad "review-impl: spec-compliance argv" "$T8"; fi
# NO --report-file anywhere
printf '%s\n' "$T8" | grep -q -- '--report-file' \
  && bad "review-impl: no --report-file passed" "$T8" \
  || ok "review-impl: no --report-file passed"
# code-quality: review --base <TASK_BASE>
if printf '%s\n' "$T8" | grep -q '^## code-quality$' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:review' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:--base' \
   && printf '%s\n' "$T8" | grep -qx 'ARG:TBASE'; then
  ok "review-impl: code-quality argv matches expected wrapper contract"
else bad "review-impl: code-quality argv" "$T8"; fi

# review-final.sh assembles the final adversarial reviewer's dispatch argv from its CLI.
FINAL_W="$HERE/review-final.sh"
PROOT="${PROOT:-$ROOT/plugin}"   # fixture plugin root (defined locally)
mkdir -p "$PROOT/skills/subagent-driven-development"
: > "$PROOT/skills/subagent-driven-development/final-code-reviewer-focus.md"
T_FINAL="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
       bash "$FINAL_W" --base IMPLBASE 2>/dev/null )"
# final-adversarial: adversarial --base <IMPL_BASE> --focus <root>/.../final-code-reviewer-focus.md
if printf '%s\n' "$T_FINAL" | grep -q '^## final-adversarial$' \
   && printf '%s\n' "$T_FINAL" | grep -qx 'ARG:adversarial' \
   && printf '%s\n' "$T_FINAL" | grep -qx 'ARG:--base' \
   && printf '%s\n' "$T_FINAL" | grep -qx 'ARG:IMPLBASE' \
   && printf '%s\n' "$T_FINAL" | grep -qx 'ARG:--focus' \
   && printf '%s\n' "$T_FINAL" | grep -qx "ARG:$PROOT/skills/subagent-driven-development/final-code-reviewer-focus.md"; then
  ok "review-final: final-adversarial argv matches expected wrapper contract"
else bad "review-final: final-adversarial argv" "$T_FINAL"; fi
# require --base; missing value fails with a clear wrapper error, not a set -u crash
FINAL_ERR="$( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" bash "$FINAL_W" --base 2>&1 )"
RC_FINAL=$?
if [ "$RC_FINAL" -ne 0 ] \
   && printf '%s\n' "$FINAL_ERR" | grep -q 'review-final: --base requires a value' \
   && ! printf '%s\n' "$FINAL_ERR" | grep -qi 'unbound variable'; then
  ok "review-final: missing --base value fails with a clear wrapper error"
else bad "review-final: missing --base value fails with a clear wrapper error" "rc=$RC_FINAL out=$FINAL_ERR"; fi

# decide_action <stdout-blob> <exit-code> : print PROCEED | RERUN_WRAPPER | FIX_AND_REREVIEW | INSPECT.
# The exit code is accepted but NOT used to decide — the decision is read from the stdout, which
# is authoritative at any exit code. This is the reference parser the SKILL.md callers model.
#
# A code-quality reviewer is PROSE: its Summary line is "(prose — 見全文)", which is NOT
# automatically a pass. Per review-impl.sh's contract the caller MUST read the "## code-quality"
# section body and treat any blocking-severity defect there as a finding. The fixtures mark such a
# defect with a "BLOCKING:" line (the senior-engineer must-fix severity), so the parser inspects
# the code-quality section body for it. (An all-clear prose body like "No blocking issues found."
# has no "BLOCKING:" line and stays PROCEED.)
decide_action() {
  local blob="$1" rc="$2" sumlines cqbody   # rc accepted to make "stdout is authoritative" explicit
  : "$rc"                                    # intentionally unused: stdout drives the decision
  sumlines="$(printf '%s\n' "$blob" | sed -n '/^=== Summary ===$/,$p')"
  if printf '%s\n' "$sumlines" | grep -q 'ERROR (tool failed'; then
    printf 'RERUN_WRAPPER'; return 0
  fi
  # A verdict/status line annotated "(tool exit N)" means the reviewer produced a result (it has a
  # Status/Verdict) but the tool then exited nonzero, so the output MAY be incomplete. This is NOT
  # auto-PROCEED and NOT a forced rerun: the caller inspects the full "## <label>" section and uses
  # judgment (re-run if truncated, otherwise act on the result). Checked BEFORE the findings branch
  # so a findings verdict whose tool also failed (its findings may be truncated) still -> INSPECT.
  if printf '%s\n' "$sumlines" | grep -q '(tool exit '; then
    printf 'INSPECT'; return 0
  fi
  if printf '%s\n' "$sumlines" | grep -Eq 'Status: Issues Found|Verdict: needs-attention'; then
    printf 'FIX_AND_REREVIEW'; return 0
  fi
  # Prose code-quality body: extract the "## code-quality" section and treat a BLOCKING-severity
  # line as a finding. code-quality is the LAST "## <label>" section before "=== Summary ===", so
  # the section runs to the "=== Summary ===" line — an internal Markdown heading inside the prose
  # body (e.g. "## Notes") is NOT a boundary, or a BLOCKING line after it would be missed. (awk,
  # portable on BSD/3.2; no GNU-only sed alternation.)
  cqbody="$(printf '%s\n' "$blob" | awk '/^## code-quality$/{c=1;next} c&&/^=== Summary ===$/{c=0} c{print}')"
  if printf '%s\n' "$cqbody" | grep -Eq '^BLOCKING:'; then
    printf 'FIX_AND_REREVIEW'; return 0
  fi
  printf 'PROCEED'
}

# Acceptance: the wrapper's stdout === Summary === block is machine-parseable and each of the
# three SKILL.md callers' control-flow is decidable from (stdout, exit-code). decide_action reads
# the Summary from stdout REGARDLESS of the exit code and returns the documented action:
#   - any "ERROR (tool failed" Summary line -> RERUN_WRAPPER (tool failure, not a review result)
#   - else any "(tool exit N)" annotation on a verdict/status line -> INSPECT (a result exists but
#     the tool failed afterward; output may be incomplete; caller reads the full section and judges
#     re-run vs act-on-result — not auto-PROCEED, not forced rerun)
#   - else any "Status: Issues Found" / "Verdict: needs-attention" -> FIX_AND_REREVIEW
#   - else a code-quality reviewer whose Summary is prose ("(prose — 見全文)") but whose
#     "## code-quality" body carries a BLOCKING finding -> FIX_AND_REREVIEW (prose is NOT
#     automatically a pass — the caller MUST read the section body for blocking findings)
#   - else (all OKAY / approve / no-blocking prose) -> PROCEED
# These are canned wrapper-stdout fixtures plus a modelled rc — no live wrapper runs.

# --- brainstorm caller shape: structural-completeness (Status:) + design-soundness (Verdict:) ---
BR_OK="$(printf '%s\n' \
  '## structural-completeness' 'Status: OKAY' '' \
  '## design-soundness' 'Verdict: approve' '' \
  '=== Summary ===' \
  '- structural-completeness: Status: OKAY' \
  '- design-soundness: Verdict: approve')"; BR_OK_RC=0
BR_ERR="$(printf '%s\n' \
  '## structural-completeness' 'Status: OKAY' '' \
  '## design-soundness' '[stderr excerpt]' 'boom' '' \
  '=== Summary ===' \
  '- structural-completeness: Status: OKAY' \
  '- design-soundness: ERROR (tool failed, exit 1)')"; BR_ERR_RC=1
BR_FIND="$(printf '%s\n' \
  '## structural-completeness' 'Status: OKAY' '' \
  '## design-soundness' 'Verdict: needs-attention' '' \
  '=== Summary ===' \
  '- structural-completeness: Status: OKAY' \
  '- design-soundness: Verdict: needs-attention')"; BR_FIND_RC=0

# --- plan caller shape: per-task (Status:) + coverage-verifier (Status:) ---
PL_OK="$(printf '%s\n' \
  '## per-task Task 1' 'Status: OKAY' '' \
  '## coverage-verifier' 'Status: OKAY' '' \
  '=== Summary ===' \
  '- per-task Task 1: Status: OKAY' \
  '- coverage-verifier: Status: OKAY')"; PL_OK_RC=0
PL_ERR="$(printf '%s\n' \
  '## per-task Task 1' '[stderr excerpt]' 'boom' '' \
  '## coverage-verifier' 'Status: OKAY' '' \
  '=== Summary ===' \
  '- per-task Task 1: ERROR (tool failed, exit 2)' \
  '- coverage-verifier: Status: OKAY')"; PL_ERR_RC=2
PL_FIND="$(printf '%s\n' \
  '## per-task Task 1' 'Status: Issues Found' '' \
  '## coverage-verifier' 'Status: OKAY' '' \
  '=== Summary ===' \
  '- per-task Task 1: Status: Issues Found' \
  '- coverage-verifier: Status: OKAY')"; PL_FIND_RC=0

# --- impl caller shape: spec-compliance (Status:) + code-quality (prose, no verdict line) ---
IM_OK="$(printf '%s\n' \
  '## spec-compliance' 'Status: OKAY' '' \
  '## code-quality' 'Clean implementation. No blocking issues found.' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: OKAY' \
  '- code-quality: (prose — 見全文)')"; IM_OK_RC=0
IM_ERR="$(printf '%s\n' \
  '## spec-compliance' 'Status: OKAY' '' \
  '## code-quality' '[stderr excerpt]' 'boom' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: OKAY' \
  '- code-quality: ERROR (tool failed, exit 2)')"; IM_ERR_RC=2
IM_FIND="$(printf '%s\n' \
  '## spec-compliance' 'Status: Issues Found' '' \
  '## code-quality' 'src/x.ts:1 magic number' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: Issues Found' \
  '- code-quality: (prose — 見全文)')"; IM_FIND_RC=0
# code-quality is PROSE — a "(prose — 見全文)" Summary line is NOT automatically a pass. Here
# spec-compliance is OKAY, the Summary shows code-quality as prose, exit 0 — but the
# "## code-quality" BODY carries a BLOCKING finding (marked "BLOCKING:" — the senior-engineer
# must-fix severity the reviewer emits). The caller MUST read the section body, so the decision
# is FIX_AND_REREVIEW, not PROCEED. This is the case review-impl.sh's contract requires.
IM_CQ_BLOCK="$(printf '%s\n' \
  '## spec-compliance' 'Status: OKAY' '' \
  '## code-quality' 'BLOCKING: src/recovery.ts:47 unhandled error path can drop data' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: OKAY' \
  '- code-quality: (prose — 見全文)')"; IM_CQ_BLOCK_RC=0
# Regression: the code-quality PROSE body may contain its own Markdown heading (e.g. "## Notes")
# BEFORE a BLOCKING line. code-quality is the last "## <label>" section before "=== Summary ===",
# so the parser must NOT treat an internal heading as the section boundary — it must keep reading
# to "=== Summary ===" and still find the BLOCKING line. Decision: FIX_AND_REREVIEW, not PROCEED.
IM_CQ_BLOCK_HEADING="$(printf '%s\n' \
  '## spec-compliance' 'Status: OKAY' '' \
  '## code-quality' '## Notes' 'general remarks about the change' \
  'BLOCKING: src/recovery.ts:47 unhandled error path can drop data' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: OKAY' \
  '- code-quality: (prose — 見全文)')"; IM_CQ_BLOCK_HEADING_RC=0

# --- final caller shape: final-adversarial (Verdict:) — single reviewer (review-final.sh) ---
FN_OK="$(printf '%s\n' \
  '## final-adversarial' 'Verdict: approve' '' \
  '=== Summary ===' \
  '- final-adversarial: Verdict: approve')"; FN_OK_RC=0
FN_ERR="$(printf '%s\n' \
  '## final-adversarial' '[stderr excerpt]' 'boom' '' \
  '=== Summary ===' \
  '- final-adversarial: ERROR (tool failed, exit 1)')"; FN_ERR_RC=1
FN_FIND="$(printf '%s\n' \
  '## final-adversarial' 'Verdict: needs-attention' '' \
  '=== Summary ===' \
  '- final-adversarial: Verdict: needs-attention')"; FN_FIND_RC=0

# --- tool-exit annotation: a verdict/status WAS produced (the review completed, a result exists)
# but the tool then exited nonzero, so the Summary line carries a "(tool exit N)" annotation and
# the output may be incomplete. Decision: INSPECT — read the full "## <label>" section and use
# judgment (re-run if truncated, otherwise act on the result). NOT auto-PROCEED, NOT forced rerun.
FN_TOOLEXIT="$(printf '%s\n' \
  '## final-adversarial' 'Verdict: approve' '' \
  '[stderr excerpt]' 'late boom' '' \
  '=== Summary ===' \
  '- final-adversarial: Verdict: approve (tool exit 1)')"; FN_TOOLEXIT_RC=1
# Tool-exit takes precedence over a findings verdict: needs-attention WITH (tool exit N) still
# decides INSPECT, because the findings list itself may be truncated by the tool failure.
FN_NA_TOOLEXIT="$(printf '%s\n' \
  '## final-adversarial' 'Verdict: needs-attention' '' \
  '=== Summary ===' \
  '- final-adversarial: Verdict: needs-attention (tool exit 1)')"; FN_NA_TOOLEXIT_RC=1
# impl shape: spec-compliance Status annotated with a tool exit -> INSPECT.
IM_TOOLEXIT="$(printf '%s\n' \
  '## spec-compliance' 'Status: OKAY' '' \
  '## code-quality' 'looks fine' '' \
  '=== Summary ===' \
  '- spec-compliance: Status: OKAY (tool exit 2)' \
  '- code-quality: (prose — 見全文)')"; IM_TOOLEXIT_RC=2

# expect_action <name> <blob> <rc> <expected-action> : assert decide_action(stdout, rc) matches.
expect_action() {
  local name="$1" blob="$2" rc="$3" want="$4" got
  got="$(decide_action "$blob" "$rc")"
  if [ "$got" = "$want" ]; then ok "$name -> $want"
  else bad "$name -> $want" "got=$got (rc=$rc)"; fi
}

# Every caller's three documented decisions (stdout drives the decision at any exit code).
expect_action "brainstorm all-clear (rc 0)"        "$BR_OK"   "$BR_OK_RC"   "PROCEED"
expect_action "brainstorm ERROR (rc nonzero)"      "$BR_ERR"  "$BR_ERR_RC"  "RERUN_WRAPPER"
expect_action "brainstorm needs-attention (rc 0)"  "$BR_FIND" "$BR_FIND_RC" "FIX_AND_REREVIEW"
expect_action "plan all-clear (rc 0)"              "$PL_OK"   "$PL_OK_RC"   "PROCEED"
expect_action "plan ERROR (rc nonzero)"            "$PL_ERR"  "$PL_ERR_RC"  "RERUN_WRAPPER"
expect_action "plan Issues Found (rc 0)"           "$PL_FIND" "$PL_FIND_RC" "FIX_AND_REREVIEW"
expect_action "impl all-clear prose (rc 0)"        "$IM_OK"   "$IM_OK_RC"   "PROCEED"
expect_action "impl ERROR (rc nonzero)"            "$IM_ERR"  "$IM_ERR_RC"  "RERUN_WRAPPER"
expect_action "impl Issues Found (rc 0)"           "$IM_FIND" "$IM_FIND_RC" "FIX_AND_REREVIEW"
# Prose is NOT auto-PROCEED: a code-quality BLOCKING finding in the body decides FIX_AND_REREVIEW
# even though its Summary line is "(prose — 見全文)" and exit code is 0.
expect_action "impl code-quality prose BLOCKING (rc 0)" "$IM_CQ_BLOCK" "$IM_CQ_BLOCK_RC" "FIX_AND_REREVIEW"
# A BLOCKING line AFTER an internal Markdown heading in the prose body must still be found.
expect_action "impl code-quality BLOCKING after internal heading (rc 0)" "$IM_CQ_BLOCK_HEADING" "$IM_CQ_BLOCK_HEADING_RC" "FIX_AND_REREVIEW"
expect_action "final all-clear (rc 0)"             "$FN_OK"   "$FN_OK_RC"   "PROCEED"
expect_action "final ERROR (rc nonzero)"           "$FN_ERR"  "$FN_ERR_RC"  "RERUN_WRAPPER"
expect_action "final needs-attention (rc 0)"       "$FN_FIND" "$FN_FIND_RC" "FIX_AND_REREVIEW"
# A "(tool exit N)" annotation on a verdict/status line -> INSPECT (a result exists but the tool
# failed; output may be incomplete; the caller judges inspect vs re-run — not auto-PROCEED).
expect_action "final approve + tool exit -> INSPECT"         "$FN_TOOLEXIT"    "$FN_TOOLEXIT_RC"    "INSPECT"
expect_action "final needs-attention + tool exit -> INSPECT" "$FN_NA_TOOLEXIT" "$FN_NA_TOOLEXIT_RC" "INSPECT"
expect_action "impl spec-compliance + tool exit -> INSPECT"  "$IM_TOOLEXIT"    "$IM_TOOLEXIT_RC"    "INSPECT"

# stdout is parsed REGARDLESS of exit code: a findings Summary delivered with a NONZERO rc still
# decides FIX_AND_REREVIEW from stdout (the rc must not override the stdout verdict). This proves
# the caller does not branch on exit code alone.
expect_action "findings stdout with nonzero rc still FIX_AND_REREVIEW" "$PL_FIND" 7 "FIX_AND_REREVIEW"

# The parser extracts a reviewer's status line from the Summary block.
printf '%s\n' "$IM_OK" | sed -n '/^=== Summary ===$/,$p' | grep -q '^- spec-compliance: Status: OKAY$' \
  && ok "parser extracts a reviewer's status from the Summary block" \
  || bad "parser extracts a reviewer's status from the Summary block" "$IM_OK"

# Engine never inspects HEAD (documented trade-off: it does not detect HEAD movement).
# The engine source must contain no git/HEAD/rev-parse/reflog references.
if grep -nE 'git |rev-parse|reflog|HEAD' "$LIB" >/dev/null 2>&1; then
  bad "engine never inspects HEAD" "$(grep -nE 'git |rev-parse|reflog|HEAD' "$LIB")"
else
  ok "engine never inspects HEAD (no git/rev-parse/reflog/HEAD in the engine source)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
