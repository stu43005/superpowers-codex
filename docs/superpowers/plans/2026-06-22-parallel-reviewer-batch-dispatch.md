# Parallel Reviewer Batch Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a batch-dispatch layer over `scripts/dispatch.sh` so each review skill launches its whole reviewer set with ONE wrapper call instead of N background Bash calls.

**Architecture:** A sourced bash library `scripts/review-batch-lib.sh` exposes `batch_init` / `batch_add` / `batch_run`; it registers jobs (argv encoded with `printf %q`), throttles them with a FIFO token-bucket, captures each job's stdout/stderr into an `mktemp -d` temp dir, then emits per-job stdout in registration order plus a `=== Summary ===` block classified from stdout verdict lines, and returns nonzero only when a job is a tool ERROR. Three thin wrappers (`review-brainstorm.sh`, `review-plan.sh`, `review-impl.sh`) parse their own CLI, register the reviewer jobs, and delegate to the engine; `dispatch.sh` itself is unchanged.

**Tech Stack:** Bash (3.2 / BSD-portable, no `wait -n`/`sort -V`/`setsid` assumptions), the existing codex companion via `scripts/dispatch.sh`.

---

## Post-Approval Design Amendment (supersedes parts of Tasks 10–13)

After the plan was approved and Tasks 1–13 were implemented, the user refined the design. The
amendment below is authoritative where it conflicts with the original Task 10–13 text:

1. **Skills only ever call the `review-*.sh` wrappers.** The three SKILL.md files must NOT
   reference `dispatch.sh` directly, nor name any internal reviewer prompt/focus sidecar
   (`spec-document-reviewer-prompt.md`, `adversarial-spec-review-focus.md`,
   `plan-document-reviewer-prompt.md`, `coverage-verifier-prompt.md`, `spec-reviewer-prompt.md`,
   `final-code-reviewer-focus.md`). Those are wrapper internals invisible to the calling agent.
   Tasks 10 and 11 were amended to strip the leftover `dispatch.sh`/prompt/focus mentions.
2. **A fourth wrapper, `scripts/review-final.sh`, was added** for the final adversarial merge
   gate: `review-final.sh --base <IMPL_BASE>` registers one `final-adversarial` job
   (`adversarial --base <IMPL_BASE> --focus .../final-code-reviewer-focus.md`) and delegates to
   the engine. Task 12's final gate now calls `review-final.sh` instead of the direct
   `dispatch.sh adversarial` call — so `skills/subagent-driven-development/SKILL.md` references no
   `dispatch.sh` at all.
3. **`implementer-prompt.md` is retained as a special case** in subagent-driven-development: the
   implementer is a Claude subagent the controller dispatches directly (it is not a codex review),
   so the skill still names `implementer-prompt.md`.
4. **Test-count deltas:** `review-final.sh` added 2 wrapper tests (pre-Task-13 count 35 → 37), and
   a Task-13 follow-up added a `review-final` caller shape (3 fixtures) plus a regression fixture
   (code-quality prose containing an internal `## ` heading before a `BLOCKING:` line) and the
   matching `decide_action` awk fix (extract the `## code-quality` body through to
   `=== Summary ===`, not stopping at internal headings).
5. **Final-gate finding — tool-exit handling (spec §4.4 / §4.5 amended).** The final adversarial
   gate flagged that a reviewer emitting a verdict and THEN exiting nonzero (a teardown crash) was
   classified as a clean pass with the batch still exiting 0, silently masking a partial tool
   failure. Resolution (Option C — faithful report, caller judges): `batch_run` now sets a nonzero
   batch exit on ANY nonzero child exit (the verdict is kept and annotated `(tool exit N)`, with the
   stderr excerpt shown); the `decide_action` reference parser gained an `INSPECT` outcome for a
   `(tool exit N)` annotation; and all three SKILL.md callers' control-flow gained a "verdict +
   `(tool exit N)` → read the full section and use judgment (re-run if truncated, else act on the
   result)" branch — neither auto-pass nor forced rerun.
6. **Final-gate finding — `_batch_classify` errexit-safety.** A later gate pass noted the
   `verdict="$(grep … | tail -1)"` line could abort under `set -euo pipefail` when a reviewer emits
   prose with no `Status:`/`Verdict:` line (grep exits 1; pipefail propagates it). In practice
   `batch_run` shields this by calling `_batch_classify` via `$(...)` (errexit is not inherited into
   command substitutions by default), but the function should not depend on its call shape — a
   `|| :` guard was added so the no-match path is non-fatal even on a direct call under errexit, with
   a regression test exercising that direct-call path.
7. **Final-gate finding — bounded `--max-parallel` validation.** A huge all-digit value (beyond the
   shell integer range, e.g. `999999999999999999999`) passed the digit-only `case` check but then
   broke the `[ "$MAX_PARALLEL" -gt "$_BATCH_MAX_CAP" ]` clamp (`integer expression expected`),
   leaving `MAX_PARALLEL` huge and hanging the token-fill loop. Fix: a digit-length short-circuit
   (`${#MAX_PARALLEL} -gt ${#_BATCH_MAX_CAP}`) clamps over-length values to the cap BEFORE the
   numeric comparison runs (the `-gt` is only evaluated when the length is in range), with a
   regression test for the huge value. Final suite: **62 passed, 0 failed**.

---

## File Structure

| File | Create/Modify | Responsibility |
| ---- | ------------- | -------------- |
| `scripts/review-batch-lib.sh` | Create | Sourced batch engine: `batch_init`, `batch_add`, `batch_run` — job registration, `--max-parallel` validation, FIFO token-bucket throttle, temp-dir capture, stdout aggregation + Summary classification, exit-code semantics, shutdown trap. |
| `scripts/review-brainstorm.sh` | Create | Thin wrapper for brainstorming: parse `--spec`/`--base`/`--max-parallel`, register the two fixed reviewers (`structural-completeness`, `design-soundness`), `batch_run`. |
| `scripts/review-plan.sh` | Create | Thin wrapper for writing-plans: parse repeated `--task`, `--plan`, `--spec`, optional `--coverage`/`--max-parallel`, register per-Task + optional coverage jobs, `batch_run`. |
| `scripts/review-impl.sh` | Create | Thin wrapper for subagent-driven-development per-task review: parse `--plan`/`--task`/`--task-base`/`--max-parallel`, register `spec-compliance` + `code-quality` jobs (no `--report-file`), `batch_run`. |
| `scripts/review-final.sh` | Create (amendment) | Thin wrapper for the subagent-driven-development final adversarial merge gate: parse `--base`/`--max-parallel`, register one `final-adversarial` job, `batch_run`. |
| `scripts/review-batch-lib.test.sh` | Create | Hermetic plain-bash tests for the engine and all three wrappers, using a stub `dispatch.sh` injected via `BATCH_DISPATCH_SH` and a fixture `PLUGIN_ROOT`. |
| `skills/subagent-driven-development/spec-reviewer-prompt.md` | Modify | Remove `[REPORT_FILE_PATH]` + report-reading lines; add calibrated evidence-verifiability rule; keep `..HEAD` diff range and `Status:` Output Contract. |
| `skills/brainstorming/SKILL.md` | Modify | Replace the two-background-call spec-review dispatch with a single `review-brainstorm.sh` call + caller control-flow. |
| `skills/writing-plans/SKILL.md` | Modify | Replace the per-Task + Coverage background dispatch with a single `review-plan.sh` call + caller control-flow. |
| `skills/subagent-driven-development/SKILL.md` | Modify | Replace two-stage per-task review with a single `review-impl.sh` call; remove the report-file (`mktemp`→`--report-file`→`rm`) wiring; route the final adversarial gate through `review-final.sh` (amendment); add caller control-flow. |

---

### Task 1: Engine skeleton + job registration + test harness scaffold

**Files:**
- Create: `scripts/review-batch-lib.sh`
- Create (Test): `scripts/review-batch-lib.test.sh`

The engine is a **sourced** library (never executed directly). The test harness follows `dispatch.test.sh` conventions: plain bash, `set -u`, `ok()`/`bad()` counters, hermetic stub `dispatch.sh` written into a temp dir, ends with `N passed, M failed` and `[ "$FAIL" -eq 0 ]`. After creating both files, mark them executable (`chmod +x`); the test file is run directly, the lib is sourced.

- [ ] **Step 1: Write the failing test (harness scaffold + stub helper + argv round-trip)**

Create `scripts/review-batch-lib.test.sh`:

```bash
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x scripts/review-batch-lib.test.sh && bash scripts/review-batch-lib.test.sh`
Expected: FAIL — the lib does not exist, so `. "$LIB"` errors and the assertion fails. Output ends with `0 passed, 1 failed`.

- [ ] **Step 3: Write minimal engine (init + add + sequential run, argv via %q)**

Create `scripts/review-batch-lib.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — output ends with `1 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: add batch dispatch engine skeleton with job registration"
```

---

### Task 2: `--max-parallel` validation + FIFO token-bucket throttle

**Files:**
- Modify: `scripts/review-batch-lib.sh`
- Test: `scripts/review-batch-lib.test.sh`

`MAX_PARALLEL` must be a positive decimal integer (`^[1-9][0-9]*$`); `0`/empty/non-numeric → fail fast nonzero (a `0` token bucket would deadlock). Clamp to a documented cap of 16. Throttle with a FIFO token-bucket (preload N tokens; each job reads one before starting, writes one back on finish) so at most `MAX_PARALLEL` jobs run concurrently — no `wait -n` needed.

- [ ] **Step 1: Write the failing tests (validation + peak concurrency)**

Append before the final `printf`/`[ "$FAIL" -eq 0 ]` lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — the engine runs sequentially and never validates `MAX_PARALLEL`. The invalid-value cases exit 0 (no validation) and the sequential run never reaches a peak of 2; the five validation `bad` lines and the concurrency `bad` line appear. Output shows `1 passed, 6 failed`.

- [ ] **Step 3: Implement validation + FIFO token-bucket in `batch_run`**

Replace the entire `batch_run` function in `scripts/review-batch-lib.sh` with:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — all earlier + new assertions pass (5 invalid-value oks via the loop + 1 concurrency ok + the 1 earlier argv ok). Output ends with `7 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: validate --max-parallel and throttle jobs with FIFO token-bucket"
```

---

### Task 3: temp dir + per-job stdout/stderr capture + stdout aggregation + Summary classification

**Files:**
- Modify: `scripts/review-batch-lib.sh`
- Test: `scripts/review-batch-lib.test.sh`

`batch_run` makes one `mktemp -d`; each job's stdout → `<tmp>/<i>.out`, stderr → `<tmp>/<i>.err`, exit code → `<tmp>/<i>.rc`. After all jobs finish, emit in **registration order**: `## <label>` + the job's stdout + blank line, then `=== Summary ===` with one line per job classified per spec §4.4:

1. Last stdout line matching `^(Status|Verdict):` → that verdict (regardless of exit code).
2. Else if exit nonzero AND no verdict line → `ERROR (tool failed, exit <rc>)` and append a stderr excerpt to that job's section.
3. Else (exit 0, no verdict line) → `(prose — 見全文)`.
4. Nonzero-but-has-verdict → verdict wins (rc just noted).

- [ ] **Step 1: Write the failing tests (aggregation + four classification cases + order)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
  batch_run 2>/dev/null )

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `batch_run` streams raw stdout with no `## <label>` headings, no `=== Summary ===`, and no captured stderr. The order, four classification, stderr-excerpt, and errexit-Summary assertions report `bad` (seven failures); the errexit "completes" assertion happens to pass. Output ends with `8 passed, 7 failed`.

- [ ] **Step 3: Implement capture + aggregation + classification**

Replace the entire `batch_run` function in `scripts/review-batch-lib.sh` with:

```bash
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
    fi
    printf '\n'
    frag="$(_batch_classify "$tmp/$i.out" "$tmp/$i.err" "$rc")"
    summary="$summary- ${_BATCH_LABELS[$i]}: $frag
"
  done
  printf '=== Summary ===\n'
  printf '%s' "$summary"

  rm -rf "$tmp"
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — all aggregation/classification/order/stderr and both errexit assertions pass. Output ends with `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: capture per-job output and emit aggregated Summary with classification"
```

---

### Task 4: exit-code semantics

**Files:**
- Modify: `scripts/review-batch-lib.sh`
- Test: `scripts/review-batch-lib.test.sh`

`batch_run` returns nonzero iff ≥1 job is ERROR (no verdict line AND nonzero exit). All-have-verdict (even `Issues Found` / `needs-attention`) → exit 0. Findings drive the SKILL round loop via stdout, NOT the batch exit code.

- [ ] **Step 1: Write the failing tests (exit 0 with Issues Found, nonzero with ERROR)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `batch_run` currently always `return 0`, so the two ERROR-case assertions wrongly see exit 0 and report `bad`; the all-verdict assertion passes. Output ends with `16 passed, 2 failed`.

- [ ] **Step 3: Implement ERROR-aware exit code**

In `scripts/review-batch-lib.sh`, inside `batch_run`'s aggregation loop, set `rc_all=1` whenever a job is an ERROR, and return it. Replace the aggregation loop's ERROR branch and the final `return 0`.

Change the ERROR-detection branch from:

```bash
    if ! grep -Eq '^(Status|Verdict):' "$tmp/$i.out" 2>/dev/null && [ "$rc" -ne 0 ]; then
      printf '\n[stderr excerpt]\n'
      tail -20 "$tmp/$i.err" 2>/dev/null
    fi
```

to:

```bash
    if ! grep -Eq '^(Status|Verdict):' "$tmp/$i.out" 2>/dev/null && [ "$rc" -ne 0 ]; then
      printf '\n[stderr excerpt]\n'
      tail -20 "$tmp/$i.err" 2>/dev/null
      rc_all=1
    fi
```

And change the final cleanup/return from:

```bash
  rm -rf "$tmp"
  return 0
}
```

to:

```bash
  rm -rf "$tmp"
  return "$rc_all"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — all three exit-code assertions pass. Output ends with `18 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: return nonzero exit only when a job is a tool ERROR"
```

---

### Task 5: shutdown trap (reliable reap + rm temp; optional best-effort process-group kill)

**Files:**
- Modify: `scripts/review-batch-lib.sh`
- Test: `scripts/review-batch-lib.test.sh`

Install a `trap` on EXIT/INT/TERM that stops launching new jobs and tears the batch down. The
**reliable primary mechanism** is: **direct-child TERM then KILL of each recorded job PID, plus
`wait`/reap**, then remove the FIFO and `rm -rf` the temp dir. This always works and is exactly
the spec's documented mechanism — it is NOT a weak fallback for the temp-dir guarantee.

**Why not claim true process-group termination as the primary path:** enabling `set -m` INSIDE
a subshell that is *already* a backgrounded job does NOT move that subshell into its own process
group — the job's pid is therefore not a real pgid, and `kill -- -$pid` would not signal the
companion subtree. So we do NOT record `$pid` as a pgid from inside the job. True process-group
termination is an **OPTIONAL best-effort enhancement** done correctly only where job control can
establish it: the ENGINE/launcher shell enables job control with `set -m` *before* each `job &`,
so each backgrounded job's pid IS its own process-group id; shutdown can then `kill -- -<pid>`
the group (TERM then KILL). This is guarded so it is skipped/harmless where job control is
unavailable (non-interactive bash 3.2 / BSD), and **no strong "grandchild always killed"
guarantee is claimed**.

**Honest isolation guarantee (always holds, even with no process-group support):** the temp dir
is `rm -rf`-ed on ANY exit path, so any companion grandchild that briefly survives can only write
into the now-removed temp dir; and each batch uses a fresh `mktemp -d` and the companion's unique
per-invocation `job.id`, so a stale grandchild cannot corrupt a fresh retry's output, aggregation,
or companion state. Test 5b always asserts THIS guarantee; it only ADDITIONALLY asserts "grandchild
killed" when process-group support is actually available, and never FAILS on platforms lacking it.

**Trap installed on entry (before the FIFO):** the EXIT/INT/TERM trap is installed IMMEDIATELY
after `mktemp -d`, BEFORE `mkfifo` and `exec 9<>`. If FIFO setup fails after the temp dir is
created, the EXIT trap still removes the temp dir instead of leaking it.

**Cleanup stays armed through aggregation:** the temp-dir `rm -rf` must run on ANY exit path —
including an interruption *during* aggregation. So the EXIT trap is NOT disarmed before the
aggregation loop; it remains armed until `batch_run` returns. The INT/TERM handler runs cleanup
then exits nonzero (no fall-through into aggregation); the EXIT handler cleans up on the normal
return path. `batch_run` removes the temp dir itself on the success path and clears `_BATCH_TMP`
so the still-armed EXIT trap's cleanup is an idempotent no-op.

**PID/PGID arrays cleared after `wait`:** once `wait` has reaped every job, `_BATCH_PIDS` and
`_BATCH_PGIDS` are emptied BEFORE the aggregation phase. If INT/TERM fires during aggregation,
`_batch_shutdown` then has no PIDs to signal — so it cannot accidentally signal an already-reaped
(and possibly PID-reused) process. Only the temp-dir cleanup remains meaningful at that point, and
it stays armed.

- [ ] **Step 1: Write the failing tests (temp gone after run; grandchild killed or isolated)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — there is no EXIT/INT/TERM trap, so the INT- and TERM-interrupted runs leave their `review-batch.*` temp dirs behind (and never signal any job). The INT and TERM temp-dir assertions report `bad`, and the new grandchild-marker assertion also reports `bad` (the temp dir is not removed, so the surviving grandchild writes its marker into the still-present `GC_RUN_DIR/gc-marker`). The process-group assertion is DIAGNOSTIC ONLY and always reports `ok` (it never gates pass/fail and is independent of platform job-control support). The four other Task 5 assertions (temp dir removed after a normal run, writes-nothing-under-proj, fresh retry, process-group diagnostic) pass. Output ends with `22 passed, 3 failed`.

- [ ] **Step 3: Implement the shutdown trap (reliable reap + optional process-group kill)**

In `scripts/review-batch-lib.sh`, replace the entire `batch_run` function with this version. It
adds `_BATCH_TMP`/`_BATCH_PIDS`/`_BATCH_PGIDS` state, `_batch_shutdown`, the EXIT/INT/TERM trap,
and — for the OPTIONAL best-effort group kill — enables job control with `set -m` in the
**launcher shell BEFORE each `job &`** (so each backgrounded job's pid is its own process-group
id) and records that pid as a candidate pgid. The reliable mechanism is direct-child TERM/KILL +
`wait`/reap + temp-dir removal, which always works. The EXIT trap stays armed through aggregation;
the success path removes the temp dir and clears `_BATCH_TMP` so the trap's cleanup is an
idempotent no-op:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — the normal run leaves no temp dir and writes nothing under the project dir; the INT- and TERM-interrupted runs reap + remove their temp dir, and a fresh retry runs cleanly. The grandchild-marker assertion passes because the run's temp dir (the marker's location) is removed on INT, so `GC_RUN_DIR/gc-marker` is absent. The process-group assertion is diagnostic only and always reports `ok`. Output ends with `25 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: add shutdown trap with best-effort process-group kill and temp cleanup"
```

---

### Task 6: `review-brainstorm.sh`

**Files:**
- Create: `scripts/review-brainstorm.sh`
- Test: `scripts/review-batch-lib.test.sh`

Parse `--spec`, `--base`, optional `--max-parallel`. Derive `SCRIPT_DIR`; set `BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"` and `PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"` (both `:-` so tests can override). Source the engine, `batch_init`, register the two reviewers from spec §5.1, `batch_run`. Mark executable.

- [ ] **Step 1: Write the failing test (argv for both reviewers matches spec §5.1)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-brainstorm.sh` does not exist, so `bash "$BRAINSTORM" ...` errors and `T6` is empty. Both assertions report `bad`. Output ends with `25 passed, 2 failed`.

- [ ] **Step 3: Write `review-brainstorm.sh`**

Create `scripts/review-brainstorm.sh`:

```bash
#!/usr/bin/env bash
# Brainstorming spec-review wrapper: dispatch the two spec reviewers in one batch.
# Usage: review-brainstorm.sh --spec <design.md> --base <SPEC_BASE> [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-brainstorm: %s requires a value\n' "$1" >&2; exit 1; }; }

SPEC=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)         need_val "$1" "$#"; SPEC="$2"; shift 2 ;;
    --base)         need_val "$1" "$#"; BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-brainstorm: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$SPEC" ] || { printf 'review-brainstorm: --spec is required\n' >&2; exit 1; }
[ -n "$BASE" ] || { printf 'review-brainstorm: --base is required\n' >&2; exit 1; }

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "structural-completeness" task \
  --prompt "$PLUGIN_ROOT/skills/brainstorming/spec-document-reviewer-prompt.md" \
  --set "SPEC_FILE_PATH=$SPEC"
batch_add "design-soundness" adversarial \
  --base "$BASE" \
  --focus "$PLUGIN_ROOT/skills/brainstorming/adversarial-spec-review-focus.md"
batch_run
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/review-brainstorm.sh && bash scripts/review-batch-lib.test.sh`
Expected: PASS — both reviewer argv assertions pass. Output ends with `27 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-brainstorm.sh scripts/review-batch-lib.test.sh
git commit -m "feat: add review-brainstorm.sh wrapper dispatching the two spec reviewers"
```

---

### Task 7: `review-plan.sh`

**Files:**
- Create: `scripts/review-plan.sh`
- Test: `scripts/review-batch-lib.test.sh`

Parse repeated `--task`, `--plan`, `--spec`, optional `--coverage`, `--max-parallel`. Each `--task "Task N"` → job labeled `per-task Task N` (spec §5.2). `--coverage` → a `coverage-verifier` job. Require ≥1 `--task` or `--coverage`, else fail fast. Mark executable.

- [ ] **Step 1: Write the failing tests (per-task argv incl. spaced id, coverage, require-one error)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-plan.sh` does not exist. All five new assertions report `bad`. Output ends with `27 passed, 5 failed`.

- [ ] **Step 3: Write `review-plan.sh`**

Create `scripts/review-plan.sh`:

```bash
#!/usr/bin/env bash
# Writing-plans review wrapper: dispatch per-Task reviewers (+ optional coverage) in
# one batch.
# Usage: review-plan.sh --plan <plan.md> --spec <design.md> \
#          --task "Task 1" [--task "Task 3" ...] [--coverage] [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-plan: %s requires a value\n' "$1" >&2; exit 1; }; }

PLAN=""; SPEC=""; COVERAGE=0
TASKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         need_val "$1" "$#"; PLAN="$2"; shift 2 ;;
    --spec)         need_val "$1" "$#"; SPEC="$2"; shift 2 ;;
    --task)         need_val "$1" "$#"; TASKS+=("$2"); shift 2 ;;
    --coverage)     COVERAGE=1; shift ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-plan: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PLAN" ] || { printf 'review-plan: --plan is required\n' >&2; exit 1; }
[ -n "$SPEC" ] || { printf 'review-plan: --spec is required\n' >&2; exit 1; }
if [ "${#TASKS[@]}" -eq 0 ] && [ "$COVERAGE" -eq 0 ]; then
  printf 'review-plan: at least one --task or --coverage is required\n' >&2
  exit 1
fi

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
if [ "${#TASKS[@]}" -gt 0 ]; then
  for tid in "${TASKS[@]}"; do
    batch_add "per-task $tid" task \
      --prompt "$PLUGIN_ROOT/skills/writing-plans/plan-document-reviewer-prompt.md" \
      --set "PLAN_FILE_PATH=$PLAN" \
      --set "SPEC_FILE_PATH=$SPEC" \
      --set "TASK_ID=$tid"
  done
fi
if [ "$COVERAGE" -eq 1 ]; then
  batch_add "coverage-verifier" task \
    --prompt "$PLUGIN_ROOT/skills/writing-plans/coverage-verifier-prompt.md" \
    --set "PLAN_FILE_PATH=$PLAN" \
    --set "SPEC_FILE_PATH=$SPEC"
fi
batch_run
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/review-plan.sh && bash scripts/review-batch-lib.test.sh`
Expected: PASS — all five assertions pass. Output ends with `32 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-plan.sh scripts/review-batch-lib.test.sh
git commit -m "feat: add review-plan.sh wrapper for per-Task and coverage reviewers"
```

---

### Task 8: `review-impl.sh`

**Files:**
- Create: `scripts/review-impl.sh`
- Test: `scripts/review-batch-lib.test.sh`

Parse `--plan`, `--task`, `--task-base`, optional `--max-parallel`. Register `spec-compliance` (task, NO `--report-file`) and `code-quality` (`review --base <TASK_BASE>`) per spec §5.3. The engine never reads HEAD — the documented trade-off. Mark executable.

- [ ] **Step 1: Write the failing tests (spec-compliance + code-quality argv; no --report-file)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-impl.sh` does not exist, so `T8` is empty: the spec-compliance and code-quality argv assertions fail (2 failures), while the "no `--report-file`" assertion passes (an empty `T8` contains no `--report-file`). Output ends with `33 passed, 2 failed`.

- [ ] **Step 3: Write `review-impl.sh`**

Create `scripts/review-impl.sh`:

```bash
#!/usr/bin/env bash
# Subagent-driven-development per-task review wrapper: dispatch spec-compliance and
# code-quality reviewers in parallel for one Task.
# Usage: review-impl.sh --plan <plan.md> --task "Task N" --task-base <TASK_BASE> \
#          [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-impl: %s requires a value\n' "$1" >&2; exit 1; }; }

PLAN=""; TASK=""; TASK_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         need_val "$1" "$#"; PLAN="$2"; shift 2 ;;
    --task)         need_val "$1" "$#"; TASK="$2"; shift 2 ;;
    --task-base)    need_val "$1" "$#"; TASK_BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-impl: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PLAN" ]      || { printf 'review-impl: --plan is required\n' >&2; exit 1; }
[ -n "$TASK" ]      || { printf 'review-impl: --task is required\n' >&2; exit 1; }
[ -n "$TASK_BASE" ] || { printf 'review-impl: --task-base is required\n' >&2; exit 1; }

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "spec-compliance" task \
  --prompt "$PLUGIN_ROOT/skills/subagent-driven-development/spec-reviewer-prompt.md" \
  --set "PLAN_FILE_PATH=$PLAN" \
  --set "TASK_ID=$TASK" \
  --set "TASK_BASE=$TASK_BASE"
batch_add "code-quality" review --base "$TASK_BASE"
batch_run
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x scripts/review-impl.sh && bash scripts/review-batch-lib.test.sh`
Expected: PASS — all three assertions pass. Output ends with `35 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-impl.sh scripts/review-batch-lib.test.sh
git commit -m "feat: add review-impl.sh wrapper for parallel spec + code-quality review"
```

---

### Task 9: `spec-reviewer-prompt.md` edit

**Files:**
- Modify: `skills/subagent-driven-development/spec-reviewer-prompt.md`
- Test (verify): grep checks below (this is a doc edit, not classic TDD).

Per spec §6: remove the `[REPORT_FILE_PATH]` placeholder and the report-reading / CLAIM lines; keep the diff range `git diff [TASK_BASE]..HEAD` (do NOT add `[TASK_HEAD]`); add the calibrated two-class evidence-verifiability rule; keep the `Status: OKAY / Issues Found` Output Contract.

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -L REPORT_FILE_PATH skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected (before edit): prints **nothing** (the file still contains `REPORT_FILE_PATH`, so `grep -L` does not list it) — confirming the edit is not yet done.

Run: `grep -ic 'inherently not diff/test-verifiable' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected (before edit): `0` — the new rule is absent. (Case-insensitive `-i` so it matches the inserted `**Inherently not diff/test-verifiable**` regardless of capitalization.)

- [ ] **Step 2: Apply the edits**

Edit 0 — reframe the opening paragraph (there is no implementer report). Change:

```
You are a spec compliance reviewer executed by the codex companion. You verify whether an
implementation matches its specification. Do NOT trust the implementer's report — read the
actual code and git history.
```

to:

```
You are a spec compliance reviewer executed by the codex companion. You verify whether an
implementation matches its specification. Verify independently from the diff and the plan;
do not assume the implementation is correct — read the actual code and git history.
```

Edit 1 — replace the header block. Change:

```
**Plan file:** [PLAN_FILE_PATH]
**Task under review:** the Task whose heading matches `[TASK_ID]` in the plan file.
**Implementer's report file:** [REPORT_FILE_PATH]
**Task base commit:** [TASK_BASE]

Read the plan file and locate the Task headed `[TASK_ID]` — that is the requirement set.
Read the implementer's report at `[REPORT_FILE_PATH]` to see what they CLAIM they built.
```

to:

```
**Plan file:** [PLAN_FILE_PATH]
**Task under review:** the Task whose heading matches `[TASK_ID]` in the plan file.
**Task base commit:** [TASK_BASE]

Read the plan file and locate the Task headed `[TASK_ID]` — that is the requirement set.
Your single source of truth for what was actually built is `git diff [TASK_BASE]..HEAD`,
NOT any prose summary.
```

Edit 2 — replace the "CRITICAL: Do Not Trust the Report" section header line and its first paragraph. Change:

```
## CRITICAL: Do Not Trust the Report

The implementer may have finished quickly. Their report may be incomplete,
inaccurate, or optimistic. You MUST verify everything independently.

**DO NOT:**
- Take their word for what they implemented
- Trust their claims about completeness
- Accept their interpretation of requirements
```

to:

```
## CRITICAL: Verify Independently From the Diff

You receive no prose summary from the implementer — only the diff and the plan. The
implementation may be incomplete, inaccurate, or optimistic. You MUST verify everything
independently from the diff.

**DO NOT:**
- Assume a requirement was met because the Task says so
- Trust commit messages as evidence of completeness
- Accept a looser interpretation of requirements than the plan states
```

Edit 3 — add the evidence-verifiability rule. After the `**Verify by reading code, not by trusting the report.**` line, change:

```
**Verify by reading code, not by trusting the report.**

## Issue Reporting Requirements
```

to:

```
**Verify by reading the diff, not by trusting any prose summary.**

## Evidence Verifiability

`git diff [TASK_BASE]..HEAD` (including committed tests) is your only source of truth.
For each acceptance item, decide which class it falls into and act accordingly:

- **Should-be-testable-but-isn't → `Status: Issues Found`.** If a requirement *could*
  be expressed as a test or be made visible in the diff (e.g. a behavior a unit test
  could cover) but no such test/diff evidence is present, do NOT pass it on weaker
  evidence. Report it and require the missing test.
- **Inherently not diff/test-verifiable → annotate and defer, do NOT hard-fail.** If an
  acceptance item *cannot* be proven by diff or test (a pure external side effect, or
  something that requires a human to operate and observe), do NOT fail the Task for that
  reason. Instead explicitly annotate in your output: "this acceptance item cannot be
  verified from diff/tests; deferred to the final adversarial merge gate + user-review
  gate for manual confirmation."

This keeps "should have tested but didn't" from sneaking through, without making an
inherently-unverifiable-but-legitimate Task impossible to ever pass.

## Issue Reporting Requirements
```

Edit 4 — reword the "Missing requirements" bullets so nothing references a claim/report.
Change:

```
**Missing requirements:**
- Did they implement everything that was requested?
- Are there requirements they skipped or missed?
- Did they claim something works but didn't actually implement it?
```

to:

```
**Missing requirements:**
- Did they implement everything the Task requires (verified from the diff)?
- Are there requirements they skipped or missed?
- Does any requirement appear unimplemented when you read the actual diff?
```

Edit 5 — reword the `**DO:**` bullet that references a claim. Change:

```
**DO:**
- Run `git diff [TASK_BASE]..HEAD` to read the actual code changes
- Compare actual implementation to the Task's requirements line by line
- Check for missing pieces they claimed to implement
- Look for extra features they didn't mention
```

to:

```
**DO:**
- Run `git diff [TASK_BASE]..HEAD` to read the actual code changes
- Compare actual implementation to the Task's requirements line by line
- Check for missing pieces the Task requires but the diff does not show
- Look for extra changes the Task did not call for
```

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -L REPORT_FILE_PATH skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: prints `skills/subagent-driven-development/spec-reviewer-prompt.md` (the file no longer contains `REPORT_FILE_PATH`, so `grep -L` lists it).

Run: `grep -ic 'inherently not diff/test-verifiable' skills/subagent-driven-development/spec-reviewer-prompt.md` (case-insensitive, matching the inserted `**Inherently not diff/test-verifiable**`)
Expected: `1`.

Run: `grep -c 'git diff \[TASK_BASE\]\.\.HEAD' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: ≥ `2` (diff range preserved; no `[TASK_HEAD]` introduced).

Run: `grep -c 'TASK_HEAD' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: `0`.

Run: `grep -ic "implementer's report\|implementer report\|REPORT_FILE_PATH" skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: `0` — no report references remain anywhere in the prompt.

Run: `grep -ic 'claim' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: `0` — the "claim/claimed" wording is gone from the opening and the Missing-requirements bullets.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/spec-reviewer-prompt.md
git commit -m "docs: drop report-file from spec reviewer, add evidence-verifiability rule"
```

---

### Task 10: `brainstorming/SKILL.md` dispatch rewrite

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Test (verify): grep checks below.

Replace the two-background-call dispatch (the "Parallel dispatch per round" + "Dispatch mechanism" + the two separate `dispatch.sh` blocks) with a single `review-brainstorm.sh` call plus the explicit caller control-flow from spec §7 (read stdout on ANY exit code; classify from `=== Summary ===`; ERROR → rerun whole wrapper; findings → fix + re-review). Also fix the stale sections that survive the dispatch block: (a) the "Round loop — zero tolerance" PSEUDOCODE (it has no ERROR branch and routes every non-pass into `fix_all_findings`); (b) the gitignored-spec instruction (it implies the design-soundness reviewer can be individually "skipped", which the fixed two-reviewer `review-brainstorm.sh` wrapper cannot express); (c) the User Review Gate "may focus" wording (the wrapper only takes `--spec`/`--base` and always re-reviews the whole spec); and (d) ADD the caller HEAD contract (spec §11: callers must not advance `HEAD` while `review-brainstorm.sh` runs).

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -c 'review-brainstorm.sh' skills/brainstorming/SKILL.md`
Expected (before edit): `0`.

- [ ] **Step 2: Apply the edits**

Edit A — Checklist item 6. Change:

```
6. **Spec review loop (dual reviewer, codex)** — capture `SPEC_BASE` before writing the spec; after committing, dispatch the structural-completeness reviewer (`dispatch.sh task`, spec-document-reviewer sidecar) and the design-soundness reviewer (`dispatch.sh adversarial`, `adversarial-spec-review-focus.md`) in parallel each round; fix ALL findings; loop until the structural-completeness reviewer returns `Status: OKAY` AND the design-soundness reviewer returns `Verdict: approve` in the same round (see below — do NOT do this inline)
```

to:

```
6. **Spec review loop (dual reviewer, codex)** — capture `SPEC_BASE` before writing the spec; after committing, dispatch both reviewers each round with ONE `review-brainstorm.sh` call (it runs the structural-completeness and design-soundness reviewers in parallel); read the wrapper's stdout `=== Summary ===` on any exit code; fix ALL findings; loop until the structural-completeness reviewer returns `Status: OKAY` AND the design-soundness reviewer returns `Verdict: approve` in the same round (see below — do NOT do this inline)
```

Edit B — Process-flow DOT diagram. The diagram has a "Spec review loop" node labelled with the two direct `dispatch.sh` calls and three edges referencing it. Replace the node-label and the three edges that mention `dispatch.sh task + ... dispatch.sh adversarial` so the loop references the single wrapper. Change:

```
    "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)" [shape=box];
```

to:

```
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [shape=box];
```

and change the three edges:

```
    "Write design doc\n+ capture SPEC_BASE" -> "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)";
    "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)" -> "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)" [label="any finding — fix all, re-dispatch both"];
    "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)" -> "User reviews spec?" [label="both OKAY + approve"];
    "User reviews spec?" -> "Spec review loop\n(structural-completeness: dispatch.sh task + design-soundness: dispatch.sh adversarial\nboth parallel, both must pass)" [label="changes requested — re-run dual loop"];
```

to:

```
    "Write design doc\n+ capture SPEC_BASE" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)";
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [label="any finding — fix all, re-run wrapper"];
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "User reviews spec?" [label="both OKAY + approve"];
    "User reviews spec?" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [label="changes requested — re-run dual loop"];
```

Edit C — replace the review-loop dispatch block. Replace the block that begins with `**Parallel dispatch per round:**` and ends with the Design Soundness `dispatch.sh adversarial` fenced code block (lines from `**Parallel dispatch per round:**` through the closing ``` of the adversarial block) with:

````
**Single batched dispatch per round:**

Each round, launch BOTH reviewers with ONE call to the batch wrapper. `${CLAUDE_PLUGIN_ROOT}`
is inline-expanded inside this SKILL.md at load time; the spec path is repo-root-relative.
Fill `<SPEC_BASE>` with the SHA captured before the spec commit; substitute the value, do not
run verbatim:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-brainstorm.sh" \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --base <SPEC_BASE>
```

This runs the structural-completeness reviewer (`dispatch.sh task`, spec-document-reviewer
sidecar) and the design-soundness reviewer (`dispatch.sh adversarial`,
`adversarial-spec-review-focus.md`) in parallel and returns ALL output on stdout.

**Caller control-flow (read stdout on ANY exit code):**

1. **Regardless of the wrapper's exit code, read and parse its entire stdout** and locate the
   `=== Summary ===` section — this is the machine-readable status, and stdout is preserved
   in full even on a nonzero exit.
2. Classify each reviewer from its Summary line: `Status: OKAY` / `Status: Issues Found`
   (structural-completeness) and `Verdict: approve` / `Verdict: needs-attention`
   (design-soundness); `ERROR (tool failed, ...)` for a tool failure; or `(prose — 見全文)`
   for a no-verdict reviewer — for a prose line, read that reviewer's full `## <label>`
   section and treat any blocking finding there the same as `Issues Found`.
3. **If any reviewer is ERROR** → **re-run the entire `review-brainstorm.sh` call** (same
   arguments). Do not treat ERROR as a review failure and do not discard stdout.
4. **Otherwise** apply the round loop: if either reviewer reports a finding, fix ALL findings,
   commit, and re-run the whole wrapper next round; when structural-completeness is
   `Status: OKAY` AND design-soundness is `Verdict: approve` in the same round, the loop ends.

**Caller HEAD contract:** Do not advance `HEAD` (commit/rebase/checkout) while
`review-brainstorm.sh` is running — both reviewers must see the same `HEAD` and the same
`<SPEC_BASE>..HEAD` diff. The engine does not detect `HEAD` movement, so the caller must
guarantee it. Commit each round's spec fixes BEFORE launching the next round's wrapper call,
not while it runs.
````

Edit D — the "Round loop — zero tolerance" PSEUDOCODE. It currently has no ERROR branch and
routes every non-pass straight into `fix_all_findings`, and it does not parse the
`=== Summary ===` block. Change:

````
**Round loop — zero tolerance:**

```
while true:
  [launch the structural-completeness and design-soundness reviewers in parallel, wait for both]
  if structural_completeness == "Status: OKAY" AND design_soundness == "Verdict: approve":
    break  # both passed — exit loop
  fix_all_findings(structural_completeness.issues + design_soundness.findings)  # every finding — none skipped
  # spec was edited — re-dispatch BOTH reviewers next round
  # (both re-run together whenever any spec edit is made)
```

Any finding from either reviewer blocks the round. Fix everything before re-dispatching.
````

to:

````
**Round loop — zero tolerance:**

```
while true:
  summary = run_review_brainstorm(spec_file, SPEC_BASE)   # ONE wrapper call, both reviewers
  parse === Summary ===   # read stdout on ANY exit code (stdout is authoritative)
  structural = structural_completeness verdict   # Status: OKAY | Issues Found | ERROR (tool failed…)
  design     = design_soundness verdict          # Verdict: approve | needs-attention | ERROR (tool failed…) | prose

  if structural is "ERROR (tool failed…)" OR design is "ERROR (tool failed…)":
    continue   # tool failure, NOT a review result — re-run the WHOLE wrapper, same args

  if structural == "Status: OKAY" AND design == "Verdict: approve":
    break   # both passed — exit loop

  # Only real reviewer findings (Issues Found / needs-attention, and any prose finding) reach here.
  fix_all_findings(structural.issues + design.findings)   # every finding — none skipped
  commit_round_fixes()
  # spec was edited — re-run the whole wrapper next round (both reviewers re-run together)
```

Any finding from either reviewer blocks the round. An `ERROR (tool failed…)` is a tool failure,
not a finding: re-run the whole wrapper rather than entering the fix loop. Fix every real finding
before re-running.
````

Edit E — the gitignored-spec instruction. The fixed two-reviewer `review-brainstorm.sh` wrapper
has no per-reviewer skip option, so the "design-soundness reviewer … must be skipped for that
round" sentence is not expressible. Change:

```
**Git commit discipline:** Before the first review round, commit the first version of the spec. After each round's fixes, commit again with a message noting the round (e.g. `docs(spec): fix review round 2 - resolve ambiguity in auth flow`). If the spec file is gitignored, skip the commit — NEVER use `git add -f` to force-add an ignored file. If the spec is gitignored, the design-soundness reviewer cannot diff the spec commit and must be skipped for that round (note the skip in output).
```

to:

```
**Git commit discipline:** Before the first review round, commit the first version of the spec. After each round's fixes, commit again with a message noting the round (e.g. `docs(spec): fix review round 2 - resolve ambiguity in auth flow`). NEVER use `git add -f` to force-add an ignored file. `review-brainstorm.sh` is a fixed two-reviewer wrapper with no per-reviewer skip option; the design-soundness reviewer diffs `<SPEC_BASE>..HEAD`, so the spec **must be committed** for the wrapper-based review to run as designed. If the spec file is gitignored, the wrapper cannot review it — do not attempt the dual review on a gitignored spec; ask the user to un-ignore (or relocate) the spec so it can be committed before review.
```

Edit F — the User Review Gate rerun instructions. The wrapper only takes `--spec`/`--base` and
always re-reviews the whole spec, so remove the "the review may focus there" implication. Change:

```
2. Re-run the dual spec review loop (both the structural-completeness and design-soundness reviewers in parallel, until both pass). If the change affects global consistency or scope, the full spec is re-reviewed; if it only affects a single section, the review may focus there — but both reviewers still re-run.
```

to:

```
2. Re-run the dual spec review loop with ONE `review-brainstorm.sh` call (both the structural-completeness and design-soundness reviewers in parallel, until both pass). The wrapper takes only `--spec`/`--base` and always re-reviews the whole spec — there is no per-section focus — so any edit re-runs both reviewers over the entire spec.
```

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -c 'review-brainstorm.sh' skills/brainstorming/SKILL.md`
Expected: ≥ `7` — the literal script name `review-brainstorm.sh` now appears in: checklist item 6, the diagram node + edges, the command block, the new-prose reference, the HEAD contract, the gitignored-spec instruction (Edit E), and the User Review Gate rerun (Edit F).

Run: `grep -c '=== Summary ===' skills/brainstorming/SKILL.md`
Expected: ≥ `1` (the caller control-flow and the round-loop pseudocode both reference the Summary block).

Run: `grep -c 'must be skipped for that round' skills/brainstorming/SKILL.md`
Expected: `0` — the per-reviewer "design-soundness reviewer … must be skipped for that round" instruction (which the fixed two-reviewer wrapper cannot express) was removed.

Run: `grep -c 'the review may focus' skills/brainstorming/SKILL.md`
Expected: `0` — the User Review Gate "the review may focus there" per-section implication was removed.

Run: `grep -ic 'ERROR (tool failed' skills/brainstorming/SKILL.md`
Expected: ≥ `1` — the round-loop pseudocode now has an explicit ERROR branch that re-runs the whole wrapper.

Run: `grep -ic 'do not advance .HEAD.' skills/brainstorming/SKILL.md`
Expected: ≥ `1` — the caller HEAD contract (spec §11: "Do not advance `HEAD` … while `review-brainstorm.sh` is running") was added.

Concrete check that the old direct-dispatch review-loop INSTRUCTIONS are gone. The review loop must no longer instruct the two separate background `dispatch.sh` calls, and the diagram/checklist must no longer drive the loop through direct `dispatch.sh task`/`dispatch.sh adversarial`:

Run: `grep -c 'separate background Bash calls' skills/brainstorming/SKILL.md`
Expected: `0` (the "Parallel dispatch per round" two-background-call instruction was removed).

Run: `grep -c 'run_in_background' skills/brainstorming/SKILL.md`
Expected: `0` (both `run_in_background: true` review-loop call instructions were removed with the old dispatch block).

Run: `grep -c '\.sh" task' skills/brainstorming/SKILL.md`
Expected: `0` (no direct `dispatch.sh task` invocation block remains in the review loop).

Run: `grep -c '\.sh" adversarial' skills/brainstorming/SKILL.md`
Expected: `0` (no direct `dispatch.sh adversarial` invocation block remains in the review loop).

Note: the bare strings `dispatch.sh task` / `dispatch.sh adversarial` still appear as descriptive prose (the reviewer-role labels in the "Spec Review Loop" section and the one-line parenthetical inside the new wrapper description); those are descriptions of what the wrapper runs, not direct-call instructions, and are intentionally retained.

- [ ] **Step 4: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "docs: rewrite brainstorming spec-review dispatch to single review-brainstorm.sh"
```

---

### Task 11: `writing-plans/SKILL.md` dispatch rewrite

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Test (verify): grep checks below.

Replace the per-Task + Coverage background dispatch (the "Dispatch mechanism" section with its two `dispatch.sh task` blocks and the surrounding "separate run_in_background Bash call" instructions) with a single `review-plan.sh` call (multiple `--task`, optional `--coverage`) plus the spec §7 caller control-flow. Also update the `### Per-Task Review` and `### Coverage Verifier` subsections that still describe per-reviewer dispatch ("Per-Task invocation", "each reviewer call passes `--set TASK_ID`", "dispatch one Coverage Verifier") to the single-wrapper model, and add `prose` to the caller control-flow classification.

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -c 'review-plan.sh' skills/writing-plans/SKILL.md`
Expected (before edit): `0`.

- [ ] **Step 2: Apply the edits**

Edit A — Plan Review Loop intro. Change:

```
After writing and saving the complete plan, do **not** perform an inline self-review. Instead, dispatch reviewers via `dispatch.sh` (see **Dispatch mechanism** below). There are two reviewer roles:

- **Per-Task reviewer:** reviews one Task at a time using `plan-document-reviewer-prompt.md`, dispatched via `dispatch.sh` (see **Dispatch mechanism**) (read-only).
- **Coverage Verifier:** reviews the whole plan against the whole spec using `coverage-verifier-prompt.md`, dispatched via `dispatch.sh` (see **Dispatch mechanism**) (read-only).
```

to:

```
After writing and saving the complete plan, do **not** perform an inline self-review. Instead, dispatch all reviewers with ONE `review-plan.sh` call (see **Dispatch mechanism** below). There are two reviewer roles:

- **Per-Task reviewer:** reviews one Task at a time using `plan-document-reviewer-prompt.md`, registered by `review-plan.sh` as one `--task "Task N"` per active Task (read-only).
- **Coverage Verifier:** reviews the whole plan against the whole spec using `coverage-verifier-prompt.md`, registered by `review-plan.sh` via `--coverage` (read-only).
```

Edit B — Dispatch mechanism subsection. Replace the entire `### Dispatch mechanism (shared `dispatch.sh`)` subsection (from its heading through the Coverage Verifier `dispatch.sh task` fenced block) with:

````
### Dispatch mechanism (shared `review-plan.sh`)

All reviewers go through ONE batch wrapper call, **run from the repository root**.
`${CLAUDE_PLUGIN_ROOT}` is inline-expanded inside this SKILL.md at load time; plan/spec
paths stay repo-root-relative.

Pass one `--task "Task N"` per active Task this round, and add `--coverage` when the Coverage
Verifier is active. The wrapper runs every reviewer in parallel and returns ALL output on
stdout. Substitute the real task ids and paths; do not run verbatim:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-plan.sh" \
  --plan docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --spec docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --task "Task 1" \
  --task "Task 3" \
  --coverage
```

Each `--task "Task N"` becomes a per-Task reviewer (label `per-task Task N`, using
`plan-document-reviewer-prompt.md`); the reviewer reads the plan file and treats every other
Task as sibling context (no Task text is pasted). `--coverage` adds the Coverage Verifier
(`coverage-verifier-prompt.md`) over the whole plan vs. whole spec. Omit `--coverage` in
rounds where the Coverage Verifier has dropped out (principle 3). At least one `--task` or
`--coverage` must be present.

**Caller control-flow (read stdout on ANY exit code):**

1. **Regardless of the wrapper's exit code, read and parse its entire stdout** and locate the
   `=== Summary ===` section — stdout is preserved in full even on a nonzero exit.
2. Classify each reviewer from its Summary line: `Status: OKAY` / `Status: Issues Found`,
   `(prose — 見全文)` (a no-verdict reviewer — read its full `## <label>` section and treat any
   blocking observation as a finding), or `ERROR (tool failed, ...)`.
3. **If any reviewer is ERROR** → **re-run the entire `review-plan.sh` call** with the same
   `--task`/`--coverage` set. Do not treat ERROR as a review failure and do not discard stdout.
4. **Otherwise** apply the unified re-run policy below: fix all issues and gaps, commit, and
   re-run next round with the next round's active `--task`/`--coverage` set; the loop ends
   when every active reviewer returns `Status: OKAY` in a single round.
````

Edit C — The Round Loop prose. Change:

```
Per-Task reviewers and the Coverage Verifier are dispatched **in parallel** within a round using separate Bash calls with `run_in_background: true`. Do not wait for all per-Task reviews to finish before launching the Coverage Verifier. When a backgrounded dispatch finishes, Claude Code notifies you automatically — do NOT poll BashOutput in a loop or otherwise wait for the output to have a value. Wait for each completion notification, then read that task's output once. Once all results are in, fix all issues and gaps together, then start the next round.
```

to:

```
Per-Task reviewers and the Coverage Verifier all run **in parallel** within a round via ONE `review-plan.sh` call — pass every active Task as a `--task "Task N"` and add `--coverage` while the Coverage Verifier is active. The wrapper returns ALL reviewers' output on stdout in one shot; read its `=== Summary ===` on any exit code. Once you have parsed every reviewer's result, fix all issues and gaps together, then start the next round.
```

Edit D — the "Use the Dispatch mechanism invocations above exactly as written" line. Change:

```
Use the **Dispatch mechanism** invocations above exactly as written — do NOT pre-probe dispatch.sh with `--help`, `ls`/`find`, or source greps before dispatching.
```

to:

```
Use the **Dispatch mechanism** `review-plan.sh` invocation above exactly as written — do NOT pre-probe `review-plan.sh` or `dispatch.sh` with `--help`, `ls`/`find`, or source greps before dispatching.
```

Edit E — Round Loop pseudo-code. The current pseudo-code has NO `ERROR` branch — a tool failure
would fall through into `collect_issues()` / `fix_all_issues()` as if it were a review finding.
Add the explicit ERROR branch (mirroring Task 10): an `ERROR (tool failed…)` line re-runs the
WHOLE `review-plan.sh` with the same `--task`/`--coverage` set, and only real findings
(Issues Found / coverage gaps / prose findings) reach the fix loop. Change:

```
    # Dispatch in parallel
    task_results = parallel(
        # reviewer reads the plan file itself for sibling-Task context (no Task text pasted)
        [dispatch_task_reviewer(task) for task in active_tasks],
        dispatch_coverage_verifier(spec_file, plan_file) if coverage_active else [],
    )

    issues = collect_issues(task_results)
```

to:

```
    # ONE review-plan.sh call dispatches every active reviewer in parallel and returns
    # all output on stdout; the reviewer reads the plan file itself for sibling-Task
    # context (no Task text pasted).
    summary = run_review_plan(
        plan_file, spec_file,
        tasks=active_tasks,
        coverage=coverage_active,
    )
    task_results = parse_summary(summary)   # read === Summary === on any exit code

    # ERROR is a tool failure, NOT a review result: re-run the WHOLE wrapper, same args.
    if any(r is "ERROR (tool failed…)" for r in task_results):
        continue   # same active_tasks / coverage_active — do not enter the fix loop

    # Only real reviewer results (Issues Found / coverage gaps / prose findings) reach here.
    issues = collect_issues(task_results)
```

Edit F — User Review Gate rerun instructions. Change:

```
2. Re-run the per-Task reviewer for every **affected Task** using the Per-Task invocation in **Dispatch mechanism** above; pass only `--set TASK_ID="Task N"` so the reviewer reads sibling Task context from the plan file.
3. Re-run the Coverage Verifier over the whole plan vs. the whole spec (edits can introduce new coverage gaps).
```

to:

```
2. Re-run review with ONE `review-plan.sh` call: pass one `--task "Task N"` for every **affected Task** so each reviewer reads sibling Task context from the plan file, and add `--coverage` to also re-run the Coverage Verifier over the whole plan vs. the whole spec (edits can introduce new coverage gaps).
```

Edit G — the `### Per-Task Review` and `### Coverage Verifier` subsections. These still describe the per-reviewer model ("Per-Task invocation", "each reviewer call passes `--set TASK_ID`", "dispatch one Coverage Verifier"). Replace BOTH subsections — from the `### Per-Task Review` heading through the end of the `### Coverage Verifier` subsection (i.e. up to but NOT including `### The Round Loop`) — with:

````
### Per-Task Review

Every active Task this round is reviewed by one per-Task reviewer, registered as a single
`--task "Task N"` on the one `review-plan.sh` call in **Dispatch mechanism** above (the wrapper
translates each `--task` into the reviewer's task id for you — you never pass any `--set` flag
yourself). The reviewer reads the plan file, locates that Task, and treats every other Task in
the file as sibling context — no Task text is pasted.

A Task that has not yet received `Status: OKAY` is passed as a `--task` each round. A Task drops
out of the loop (its `--task` is omitted next round) once its reviewer reports `Status: OKAY` and
its content is not edited again.

### Coverage Verifier

In **addition** to the per-Task reviews, add `--coverage` to the same `review-plan.sh` call each
round the Coverage Verifier is active (it uses `coverage-verifier-prompt.md` over the whole plan
file and whole spec file, read-only, comparing them globally).

If it returns coverage gaps, fill every gap: add Tasks, strengthen existing Tasks, or amend the
spec. Any newly added or substantially changed Task re-enters per-Task review next round (as a new
`--task`). Keep `--coverage` on next round only if gaps were fixed this round; otherwise omit it.
````

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -c 'review-plan.sh' skills/writing-plans/SKILL.md`
Expected: ≥ `7` — the literal `review-plan.sh` now appears in: Plan Review Loop intro (×2 bullets), Dispatch mechanism heading + command block + prose, Round Loop prose, the "exactly as written" line, the User Review Gate rerun, and the Per-Task Review + Coverage Verifier subsections (Edit G).

Run: `grep -c '=== Summary ===' skills/writing-plans/SKILL.md`
Expected: ≥ `1`.

Run (Round Loop pseudo-code now has an explicit `ERROR → re-run the WHOLE wrapper` branch, not a fall-through into the fix loop): `awk '/^### The Round Loop$/,/^### Git Commit Discipline$/' skills/writing-plans/SKILL.md | grep -Eic 'ERROR \(tool failed.*re-run the WHOLE wrapper|re-run the WHOLE wrapper, same args'`
Expected: ≥ `1` — the Round Loop section contains the `ERROR (tool failed…)` → re-run the whole wrapper path (same `--task`/`--coverage` set), distinct from the Issues Found / coverage-gap / prose findings that go to the fix loop.

Run: `grep -c 'run_in_background' skills/writing-plans/SKILL.md`
Expected: `0` (every per-reviewer separate-background-call instruction — Dispatch mechanism, The Round Loop — was removed).

Run: `grep -c '\.sh" task' skills/writing-plans/SKILL.md`
Expected: `0` (no direct `dispatch.sh task` invocation block remains in the review loop).

Run: `grep -Ec 'dispatch_task_reviewer|dispatch_coverage_verifier' skills/writing-plans/SKILL.md`
Expected: `0` (the pseudo-code now calls `run_review_plan`, not the per-reviewer dispatch helpers).

Run: `grep -c -- '--set TASK_ID' skills/writing-plans/SKILL.md`
Expected: `0` — the caller no longer passes `--set TASK_ID` directly; the User Review Gate and Per-Task Review now use `--task "Task N"` (Edit F + Edit G removed the last `--set TASK_ID` instruction).

Run: `grep -c 'Per-Task invocation' skills/writing-plans/SKILL.md`
Expected: `0` — the "using the Per-Task invocation in Dispatch mechanism" phrasing was replaced by the single-wrapper `--task` model.

Run: `grep -c 'Coverage Verifier invocation' skills/writing-plans/SKILL.md`
Expected: `0` — the "using the Coverage Verifier invocation in Dispatch mechanism" phrasing was replaced by `--coverage` on the one wrapper call.

Run: `grep -c 'prose — 見全文\|(prose' skills/writing-plans/SKILL.md`
Expected: ≥ `1` — `prose` was added to the caller control-flow classification (a no-verdict reviewer).

- [ ] **Step 4: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "docs: rewrite writing-plans review dispatch to single review-plan.sh"
```

---

### Task 12: `subagent-driven-development/SKILL.md` dispatch rewrite

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Test (verify): grep checks below.

Replace the two-stage per-task review (the "Spec-compliance reviewer" + "Code-quality reviewer" subsections and the report-file `mktemp`→`--report-file`→`rm` wiring) with a single `review-impl.sh` call (spec + code-quality parallel, §5.3 contract). REMOVE every mention of the report-file wiring (incl. the process diagram's `--report-file` node, the Example Workflow lines, and the Sidecar files line). Keep the final adversarial merge gate unchanged. Add the §7 caller control-flow (incl. `prose` classification for code-quality). Also update the Advantages "Quality gates" bullet (no longer two-stage) and shape the Example Workflow so the `=== Summary ===` block holds ONLY final status lines while full reviewer output appears in the `## <label>` sections BEFORE Summary (spec §4.4).

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -c -- '--report-file' skills/subagent-driven-development/SKILL.md`
Expected (before edit): a positive number (the report-file wiring is present).

Run: `grep -c 'review-impl.sh' skills/subagent-driven-development/SKILL.md`
Expected (before edit): `0`.

- [ ] **Step 2: Apply the edits**

Edit A — opening paragraph. Change:

```
Execute plan by dispatching fresh subagent per task, with two-stage review after each: the spec-compliance reviewer first (`dispatch.sh task` with `--report-file`), then the code-quality reviewer (`dispatch.sh review`). After all tasks pass, a single final adversarial reviewer (`dispatch.sh adversarial`) gates the merge.
```

to:

```
Execute plan by dispatching fresh subagent per task, with a single batched review after each: the spec-compliance and code-quality reviewers run in parallel via one `review-impl.sh` call. After all tasks pass, a single final adversarial reviewer (`dispatch.sh adversarial`) gates the merge.
```

Edit B — core principle. Change:

```
**Core principle:** Fresh subagent per task + two-stage review (spec then quality) + one final adversarial gate = high quality, fast iteration
```

to:

```
**Core principle:** Fresh subagent per task + one batched review (spec + quality in parallel) + one final adversarial gate = high quality, fast iteration
```

Edit C — process diagram. In the `cluster_per_task` subgraph, replace the two reviewer nodes and their edges so the spec→quality serialization becomes one batched review. Change the node lines:

```
        "Dispatch spec-compliance reviewer (dispatch.sh task, --report-file)" [shape=box];
        "Status: OKAY?" [shape=diamond];
        "Implementer fixes spec gaps, re-commit" [shape=box];
        "Dispatch code-quality reviewer (dispatch.sh review)" [shape=box];
        "Prose: any blocking finding?" [shape=diamond];
        "Implementer fixes quality issues, re-commit" [shape=box];
```

to:

```
        "Dispatch spec + code-quality reviewers (review-impl.sh, parallel)" [shape=box];
        "Any ERROR / blocking finding?" [shape=diamond];
        "Implementer fixes all findings, re-commit" [shape=box];
```

And change the edges:

```
    "Implementer subagent implements, tests, commits, self-reviews" -> "Dispatch spec-compliance reviewer (dispatch.sh task, --report-file)";
    "Dispatch spec-compliance reviewer (dispatch.sh task, --report-file)" -> "Status: OKAY?";
    "Status: OKAY?" -> "Implementer fixes spec gaps, re-commit" [label="no"];
    "Implementer fixes spec gaps, re-commit" -> "Dispatch spec-compliance reviewer (dispatch.sh task, --report-file)" [label="re-review"];
    "Status: OKAY?" -> "Dispatch code-quality reviewer (dispatch.sh review)" [label="yes"];
    "Dispatch code-quality reviewer (dispatch.sh review)" -> "Prose: any blocking finding?";
    "Prose: any blocking finding?" -> "Implementer fixes quality issues, re-commit" [label="yes"];
    "Implementer fixes quality issues, re-commit" -> "Dispatch code-quality reviewer (dispatch.sh review)" [label="re-review"];
    "Prose: any blocking finding?" -> "Mark task complete in TodoWrite" [label="no"];
```

to:

```
    "Implementer subagent implements, tests, commits, self-reviews" -> "Dispatch spec + code-quality reviewers (review-impl.sh, parallel)";
    "Dispatch spec + code-quality reviewers (review-impl.sh, parallel)" -> "Any ERROR / blocking finding?";
    "Any ERROR / blocking finding?" -> "Dispatch spec + code-quality reviewers (review-impl.sh, parallel)" [label="ERROR — rerun whole wrapper"];
    "Any ERROR / blocking finding?" -> "Implementer fixes all findings, re-commit" [label="findings"];
    "Implementer fixes all findings, re-commit" -> "Dispatch spec + code-quality reviewers (review-impl.sh, parallel)" [label="re-review"];
    "Any ERROR / blocking finding?" -> "Mark task complete in TodoWrite" [label="all clear"];
```

Edit D — Base SHA Tracking, `TASK_BASE` bullet. Change:

```
- **`TASK_BASE`** — run `git rev-parse HEAD` immediately before dispatching each task's implementer. Reset for each task. This is the base for the spec-compliance reviewer's `git diff <TASK_BASE>..HEAD` (which Codex runs itself) and for the code-quality reviewer's `dispatch.sh review --base <TASK_BASE>`.
```

to:

```
- **`TASK_BASE`** — run `git rev-parse HEAD` immediately before dispatching each task's implementer. Reset for each task. This is the `--task-base` passed to `review-impl.sh`: the base for the spec-compliance reviewer's `git diff <TASK_BASE>..HEAD` (which Codex runs itself) and for the code-quality reviewer's `review --base <TASK_BASE>`. **Do not advance `HEAD` (commit/rebase/checkout) while `review-impl.sh` is running** — both reviewers must see the same HEAD (the engine does not detect HEAD movement; this is a documented caller contract).
```

Edit E — replace the entire `## Reviewer Dispatch` section from its heading through the end of the `### Code-quality reviewer` subsection (i.e. up to but NOT including `### Final adversarial reviewer`) with:

````
## Reviewer Dispatch

The per-task spec-compliance and code-quality reviewers run in parallel through ONE
`review-impl.sh` call, **run from the repository root**. Run it as written — do NOT pre-probe
`review-impl.sh` or `dispatch.sh` with `--help`, `ls`/`find`, or source greps before
dispatching. `${CLAUDE_PLUGIN_ROOT}` is inline-expanded at load time.

### Per-task batched review (spec-compliance + code-quality)

Fill `<TASK_BASE>` with the SHA captured before this task's implementer started, the plan
path with the real plan, and `"Task N"` with the actual Task heading. Substitute the values;
do not run verbatim. **Spec-compliance now verifies directly from the task's diff
(`git diff <TASK_BASE>..HEAD`); nothing extra is created, passed, or cleaned up between
implementer and reviewer:**

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-impl.sh" \
  --plan docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --task "Task N" \
  --task-base <TASK_BASE>
```

This launches both reviewers in parallel and returns ALL output on stdout:
`spec-compliance` (`dispatch.sh task`, `spec-reviewer-prompt.md`, final line
`Status: OKAY | Issues Found`) and `code-quality` (native `dispatch.sh review`, free-form
prose — no `Verdict:` line).

**Caller control-flow (read stdout on ANY exit code):**

1. **Regardless of the wrapper's exit code, read and parse its entire stdout** and locate the
   `=== Summary ===` section — stdout is preserved in full even on a nonzero exit.
2. Classify each reviewer from its Summary line: spec-compliance as
   `Status: OKAY` / `Status: Issues Found`; code-quality as `(prose — 見全文)` — read its full
   `## code-quality` section and treat any blocking-severity defect as a finding; or
   `ERROR (tool failed, ...)`.
3. **If either reviewer is ERROR** → **re-run the entire `review-impl.sh` call** (same
   `--plan`/`--task`/`--task-base`). Do not treat ERROR as a review failure and do not discard
   stdout.
4. **Otherwise**, if either reviewer has a blocking finding, the implementer fixes ALL findings
   from both reviewers in one pass, re-commits, and you re-run the whole `review-impl.sh` call
   (both reviewers re-run against the same `<TASK_BASE>` and the new HEAD). The Task passes only
   when, in a single batch with no further edits, spec-compliance is `Status: OKAY` and
   code-quality has no blocking finding.

**Code-quality severity calibration:** "blocking" = what a senior engineer would require fixed
before merge — bugs, data-loss risks, broken error handling, security issues, missing critical
test coverage. Style preferences do not trigger a re-review loop. **Do not ask the user** — the
loop runs automatically until the gate clears.
````

Edit F — Sidecar files line. Change:

```
- `./spec-reviewer-prompt.md` — spec-compliance reviewer prompt, dispatched via `dispatch.sh task --report-file`; parses `Status: OKAY | Issues Found`
```

to:

```
- `./spec-reviewer-prompt.md` — spec-compliance reviewer prompt, dispatched via `review-impl.sh` (no report file); parses `Status: OKAY | Issues Found`
```

Edit G — Example Workflow. Replace the two spec/quality dispatch line pairs. Change:

```
[Dispatch spec-compliance reviewer: dispatch.sh task --report-file (TASK_BASE=abc1234)]
Spec reviewer: Status: OKAY

[Dispatch code-quality reviewer: dispatch.sh review --base abc1234]
Code reviewer prose: Clean implementation. No blocking issues found.
[No blocking findings -> quality gate passes]
```

to:

```
[Dispatch batched review: review-impl.sh --task "Task 1" --task-base abc1234]
## spec-compliance
Status: OKAY

## code-quality
Clean implementation. No blocking issues found.

=== Summary ===
- spec-compliance: Status: OKAY
- code-quality: (prose — 見全文)
[spec OKAY + no blocking findings -> task passes]
```

And change:

```
[Dispatch spec-compliance reviewer: dispatch.sh task --report-file (TASK_BASE=def5678)]
Spec reviewer: Status: Issues Found
  - src/recovery.ts:47 — Missing progress reporting (spec says "report every 100 items")
    Fix: [concrete patch provided]
  - src/recovery.ts:112 — Extra --json flag not in spec
    Fix: [concrete removal patch provided]

[Implementer applies both fixes, re-commits]

[Spec reviewer reviews again]
Spec reviewer: Status: OKAY

[Dispatch code-quality reviewer: dispatch.sh review --base def5678]
Code reviewer prose: src/recovery.ts:47 uses magic number 100 — should be a named constant.
[Blocking finding: dispatch implementer to fix]

[Implementer extracts PROGRESS_INTERVAL constant, re-commits]

[Code quality reviewer reviews again]
Code reviewer prose: Clean. No issues.
[No blocking findings -> quality gate passes]
```

to:

```
[Dispatch batched review: review-impl.sh --task "Task 2" --task-base def5678]
## spec-compliance
Status: Issues Found
  - src/recovery.ts:47 — Missing progress reporting (spec says "report every 100 items")
    Fix: [concrete patch provided]
  - src/recovery.ts:112 — Extra --json flag not in spec
    Fix: [concrete removal patch provided]

## code-quality
src/recovery.ts:47 uses magic number 100 — should be a named constant.

=== Summary ===
- spec-compliance: Status: Issues Found
- code-quality: (prose — 見全文)

[Implementer applies ALL findings from both reviewers in one pass, re-commits]

[Re-run batched review: review-impl.sh --task "Task 2" --task-base def5678]
## spec-compliance
Status: OKAY

## code-quality
Clean. No issues.

=== Summary ===
- spec-compliance: Status: OKAY
- code-quality: (prose — 見全文)
[spec OKAY + no blocking findings -> task passes]
```

Edit H — Red Flags. Remove the now-invalid ordering flag. Change:

```
- **Start code quality review before spec compliance returns `Status: OKAY`** (wrong order)
- Move to next task while either review has open issues
```

to:

```
- Advance HEAD (commit/rebase/checkout) while `review-impl.sh` is running (both reviewers must see the same HEAD)
- Move to next task while either review has open issues
```

Edit I — the Advantages "Quality gates" bullet (still describes the removed two-stage serialization). Change:

```
- Two-stage review: spec compliance (`dispatch.sh task`), then code quality (`dispatch.sh review`)
- Final adversarial gate (`dispatch.sh adversarial`) catches cross-task integration problems
```

to:

```
- One batched review per task: spec compliance and code quality run in parallel via `review-impl.sh`
- Final adversarial gate (`dispatch.sh adversarial`) catches cross-task integration problems
```

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -c -- '--report-file' skills/subagent-driven-development/SKILL.md`
Expected: `0` (all report-file wiring removed).

Run: `grep -c 'mktemp' skills/subagent-driven-development/SKILL.md`
Expected: `0` (the report-file `mktemp` step removed; verify no other `mktemp` remained — there was none).

Run: `grep -c 'review-impl.sh' skills/subagent-driven-development/SKILL.md`
Expected: ≥ `4` (opening paragraph, diagram nodes, dispatch block, example workflow).

Run: `grep -c '=== Summary ===' skills/subagent-driven-development/SKILL.md`
Expected: ≥ `1`.

Run: `grep -c 'dispatch.sh adversarial' skills/subagent-driven-development/SKILL.md`
Expected: ≥ `1` (the final adversarial gate is unchanged).

Run: `grep -c 'Two-stage review' skills/subagent-driven-development/SKILL.md`
Expected: `0` (the Advantages "Quality gates" two-stage bullet was reworded to the one batched review).

Run: `grep -c 'Start code quality review before spec compliance' skills/subagent-driven-development/SKILL.md`
Expected: `0` (the now-invalid ordering Red Flag was removed).

Run: `grep -c 'prose — 見全文' skills/subagent-driven-development/SKILL.md`
Expected: ≥ `1` (the caller control-flow and Example Workflow classify code-quality as `(prose — 見全文)`).

Verify the Example Workflow matches the spec §4.4 shape — the `=== Summary ===` block holds ONLY the per-reviewer status lines, with full reviewer detail in the `## <label>` sections that precede it. Run: `awk '/^=== Summary ===$/{f=1;next} f&&/^## /{f=0} f&&/Fix: \[concrete/{print "LEAK"}' skills/subagent-driven-development/SKILL.md | grep -c LEAK`
Expected: `0` — no concrete-fix detail leaks into a Summary block (detail lives only in the `## spec-compliance` / `## code-quality` sections above each Summary).

**Compatibility inventory verification (the report-file channel survives where it must, and this plan does not touch the implementer prompt):**

Run: `grep -c -- '--report-file' scripts/dispatch.sh`
Expected: ≥ `1` — `dispatch.sh` still supports the general `--report-file` option (only `review-impl.sh` stopped using it; it is not dead code).

`implementer-prompt.md` is NOT modified by this plan (its report is the subagent's return message
to the parent, not a disk file, and stays as-is). Verify this base-independently — do NOT use a
relative `HEAD~N`, whose depth is unknowable at Task 12 time (Task 13 does not exist yet and the
number of commits preceding this Task is not fixed).

Run: `git status --porcelain skills/subagent-driven-development/implementer-prompt.md`
Expected: prints nothing — the file has no uncommitted modification at this point (this plan never
edits it). This check is independent of how many commits precede Task 12.

Run (the file is also absent from every Task's `Files:` block, so no Task is even scheduled to
touch it — scan only the `Create:`/`Modify:` target lines, not prose): `awk '/^\*\*Files:\*\*/{f=1;next} /^###|^## /{f=0} f&&/^- (Create|Modify|Test)/' docs/superpowers/plans/2026-06-22-parallel-reviewer-batch-dispatch.md | grep -c 'implementer-prompt.md'`
Expected: `0` — `implementer-prompt.md` never appears as a Create/Modify/Test target in any Task's
`Files:` block, confirming the plan does not modify it.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "docs: rewrite per-task review to single review-impl.sh, drop report-file wiring"
```

---

### Task 13: caller control-flow acceptance fixture (each SKILL.md caller's decision is machine-decidable)

**Files:**
- Test: `scripts/review-batch-lib.test.sh`

The agent-facing contract is the wrapper's stdout `=== Summary ===` block plus the per-caller
control-flow decision: stdout is parsed REGARDLESS of exit code; an `ERROR (tool failed…)` line →
"rerun entire wrapper"; findings (`Status: Issues Found` / `Verdict: needs-attention`, **or a
blocking finding in a prose code-quality body**) → "fix + re-review"; all-clear → "proceed". A
code-quality reviewer's `(prose — 見全文)` Summary line is NOT automatically a pass — per
`review-impl.sh`'s contract the caller MUST read the `## code-quality` section body and treat a
blocking-severity defect there as a finding. This task proves the decision is machine-decidable for
**each of the three SKILL.md callers' shapes** (brainstorm: `Status:` + `Verdict:`; plan:
per-task + coverage `Status:`; impl: spec-compliance `Status:` + code-quality prose, including a
prose body that carries a blocking finding), modelling BOTH the stdout blob AND the exit code
(0 vs nonzero) for every caller. It tests the CONTRACT/format, not any live agent or companion.

- [ ] **Step 1: Write the failing assertions (no helper yet — genuine RED)**

The reference parser `decide_action` is the production code this step is testing; the genuine-RED
step appends the ASSERTIONS that call it WITHOUT defining it, so they fail (the undefined
`decide_action` substitutes to empty, which never matches the expected action). Append the
following before the final `printf`/`[ "$FAIL" -eq 0 ]` lines of `scripts/review-batch-lib.test.sh`:

```bash
# Acceptance: the wrapper's stdout === Summary === block is machine-parseable and each of the
# three SKILL.md callers' control-flow is decidable from (stdout, exit-code). decide_action reads
# the Summary from stdout REGARDLESS of the exit code and returns the documented action:
#   - any "ERROR (tool failed" Summary line -> RERUN_WRAPPER (tool failure, not a review result)
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
```

- [ ] **Step 2: Run test to verify it fails (genuine RED — `decide_action` not yet defined)**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `decide_action` is not defined yet, so each `expect_action` call captures empty
output (`got=`) which never equals the expected action: the ten per-caller decision assertions
(nine documented decisions + the code-quality prose-BLOCKING decision) plus the "findings with
nonzero rc" assertion report `bad` (11 failures). The two helper-independent assertions (parser
extracts a status line; engine never inspects HEAD) pass. Output ends with `37 passed, 11 failed`.

- [ ] **Step 3: Define the `decide_action` reference parser (GREEN)**

Append the `decide_action` definition ABOVE the assertion block from Step 1 (so it is defined
before first use), in `scripts/review-batch-lib.test.sh`. It reads the Summary from stdout
regardless of the exit code argument (the rc is accepted to make the contract explicit — stdout is
authoritative — but the decision is taken from the Summary text, never from the rc):

```bash
# decide_action <stdout-blob> <exit-code> : print PROCEED | RERUN_WRAPPER | FIX_AND_REREVIEW.
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
  if printf '%s\n' "$sumlines" | grep -Eq 'Status: Issues Found|Verdict: needs-attention'; then
    printf 'FIX_AND_REREVIEW'; return 0
  fi
  # Prose code-quality body: extract the "## code-quality" section (up to the next "## " heading or
  # the "=== Summary ===" line — awk, portable on BSD/3.2; no GNU-only sed alternation) and treat a
  # BLOCKING-severity line as a finding.
  cqbody="$(printf '%s\n' "$blob" | awk '/^## code-quality$/{c=1;next} c&&/^## /{c=0} c&&/^=== Summary ===$/{c=0} c{print}')"
  if printf '%s\n' "$cqbody" | grep -Eq '^BLOCKING:'; then
    printf 'FIX_AND_REREVIEW'; return 0
  fi
  printf 'PROCEED'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — every caller's documented decisions hold (including the impl code-quality
prose-BLOCKING case deciding FIX_AND_REREVIEW, proving prose is not auto-PROCEED), the
nonzero-rc-findings case still decides from stdout, the parser extracts a status line, and the
engine source contains no HEAD inspection. Output ends with `48 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.test.sh
git commit -m "test: add caller control-flow acceptance fixtures for the Summary contract"
```

---

## Final verification

After Task 13, run the full engine + acceptance test suite once more and confirm it is green:

Run: `bash scripts/review-batch-lib.test.sh`
Expected: `48 passed, 0 failed` and exit 0.

Confirm `dispatch.sh` and its tests were never touched. Verify base-independently — do NOT use a
relative `HEAD~N`, whose depth depends on how many commits precede this plan's work:

Run: `git status --porcelain scripts/dispatch.sh scripts/dispatch.test.sh`
Expected: prints nothing — neither file has any uncommitted modification (this plan never edits
them).

Run (the plan never lists them as a Create/Modify target either): `awk '/^\*\*Files:\*\*/{f=1;next} /^###|^## /{f=0} f&&/^- (Create|Modify|Test)/' docs/superpowers/plans/2026-06-22-parallel-reviewer-batch-dispatch.md | grep -Ec 'scripts/dispatch\.(sh|test\.sh)'`
Expected: `0` — `dispatch.sh` / `dispatch.test.sh` appear in no Task's `Files:` block.
