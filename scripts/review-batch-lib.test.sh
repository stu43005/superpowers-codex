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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
