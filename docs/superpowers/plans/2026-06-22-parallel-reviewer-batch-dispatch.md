# Parallel Reviewer Batch Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a batch-dispatch layer over `scripts/dispatch.sh` so each review skill launches its whole reviewer set with ONE wrapper call instead of N background Bash calls.

**Architecture:** A sourced bash library `scripts/review-batch-lib.sh` exposes `batch_init` / `batch_add` / `batch_run`; it registers jobs (argv encoded with `printf %q`), throttles them with a FIFO token-bucket, captures each job's stdout/stderr into an `mktemp -d` temp dir, then emits per-job stdout in registration order plus a `=== Summary ===` block classified from stdout verdict lines, and returns nonzero only when a job is a tool ERROR. Three thin wrappers (`review-brainstorm.sh`, `review-plan.sh`, `review-impl.sh`) parse their own CLI, register the reviewer jobs, and delegate to the engine; `dispatch.sh` itself is unchanged.

**Tech Stack:** Bash (3.2 / BSD-portable, no `wait -n`/`sort -V`/`setsid` assumptions), the existing codex companion via `scripts/dispatch.sh`.

---

## File Structure

| File | Create/Modify | Responsibility |
| ---- | ------------- | -------------- |
| `scripts/review-batch-lib.sh` | Create | Sourced batch engine: `batch_init`, `batch_add`, `batch_run` — job registration, `--max-parallel` validation, FIFO token-bucket throttle, temp-dir capture, stdout aggregation + Summary classification, exit-code semantics, shutdown trap. |
| `scripts/review-brainstorm.sh` | Create | Thin wrapper for brainstorming: parse `--spec`/`--base`/`--max-parallel`, register the two fixed reviewers (`structural-completeness`, `design-soundness`), `batch_run`. |
| `scripts/review-plan.sh` | Create | Thin wrapper for writing-plans: parse repeated `--task`, `--plan`, `--spec`, optional `--coverage`/`--max-parallel`, register per-Task + optional coverage jobs, `batch_run`. |
| `scripts/review-impl.sh` | Create | Thin wrapper for subagent-driven-development: parse `--plan`/`--task`/`--task-base`/`--max-parallel`, register `spec-compliance` + `code-quality` jobs (no `--report-file`), `batch_run`. |
| `scripts/review-batch-lib.test.sh` | Create | Hermetic plain-bash tests for the engine and all three wrappers, using a stub `dispatch.sh` injected via `BATCH_DISPATCH_SH` and a fixture `PLUGIN_ROOT`. |
| `skills/subagent-driven-development/spec-reviewer-prompt.md` | Modify | Remove `[REPORT_FILE_PATH]` + report-reading lines; add calibrated evidence-verifiability rule; keep `..HEAD` diff range and `Status:` Output Contract. |
| `skills/brainstorming/SKILL.md` | Modify | Replace the two-background-call spec-review dispatch with a single `review-brainstorm.sh` call + caller control-flow. |
| `skills/writing-plans/SKILL.md` | Modify | Replace the per-Task + Coverage background dispatch with a single `review-plan.sh` call + caller control-flow. |
| `skills/subagent-driven-development/SKILL.md` | Modify | Replace two-stage per-task review with a single `review-impl.sh` call; remove the report-file (`mktemp`→`--report-file`→`rm`) wiring; keep the final adversarial gate; add caller control-flow. |

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

# --- Task 1: argv round-trip incl. a value containing a space ---
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
  : "${MAX_PARALLEL:=5}"
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

# batch_run: execute the queue (sequential for now) through BATCH_DISPATCH_SH and
# stream each job's stdout. Throttling/capture/aggregation arrive in later tasks.
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
# --- Task 2: invalid MAX_PARALLEL fails fast ---
for bad_mp in 0 "" abc 3x; do
  ( BATCH_DISPATCH_SH="$ECHO_STUB"; . "$LIB"; MAX_PARALLEL="$bad_mp"; batch_init
    batch_add j task --base HEAD; batch_run ) >/dev/null 2>&1
  if [ "$?" -ne 0 ]; then ok "invalid --max-parallel '$bad_mp' fails fast"
  else bad "invalid --max-parallel '$bad_mp' fails fast" "rc=0"; fi
done

# --- Task 2: peak concurrency never exceeds MAX_PARALLEL ---
# Stub appends "+" on start and "-" on finish to a shared file, with a short sleep,
# so a post-hoc scan of the running count never exceeds the cap.
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
[ "$peak" -le 2 ] && [ "$peak" -ge 1 ] \
  && ok "peak concurrency <= MAX_PARALLEL (peak=$peak)" \
  || bad "peak concurrency <= MAX_PARALLEL" "peak=$peak"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — the engine runs sequentially and never validates `MAX_PARALLEL`. The invalid-value cases exit 0 (no validation) and the concurrency scan may report `peak` of 1 only by accident; the validation `bad` lines appear. Output shows `1 passed, N failed`.

- [ ] **Step 3: Implement validation + FIFO token-bucket in `batch_run`**

Replace the entire `batch_run` function in `scripts/review-batch-lib.sh` with:

```bash
# _batch_validate_max_parallel: enforce ^[1-9][0-9]*$ and clamp to MAX_PARALLEL_CAP (16).
_BATCH_MAX_CAP=16
_batch_validate_max_parallel() {
  case "$MAX_PARALLEL" in
    ''|*[!0-9]*) printf 'review-batch: --max-parallel must be a positive integer, got: %s\n' "${MAX_PARALLEL:-<empty>}" >&2; return 1 ;;
  esac
  [ "$MAX_PARALLEL" -ge 1 ] || { printf 'review-batch: --max-parallel must be >= 1, got: %s\n' "$MAX_PARALLEL" >&2; return 1; }
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
  : "${MAX_PARALLEL:=5}"
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
Expected: PASS — all Task 1 + Task 2 assertions pass (5 invalid-value oks via the loop + 1 concurrency ok + Task 1's 1). Output ends with `6 passed, 0 failed`.

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
# --- Task 3: stdout aggregation, classification, registration order ---
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `batch_run` streams raw stdout with no `## <label>` headings, no `=== Summary ===`, no captured stderr. The new assertions report `bad`. Output ends with `6 passed, N failed`.

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
batch_run() {
  : "${MAX_PARALLEL:=5}"
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
      "$BATCH_DISPATCH_SH" "$@" > "$tmp/$i.out" 2> "$tmp/$i.err"
      printf '%s' "$?" > "$tmp/$i.rc"
      printf '\n' >&9
    ) &
  done
  wait
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
Expected: PASS — all aggregation/classification/order/stderr assertions pass. Output ends with `12 passed, 0 failed`.

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
# --- Task 4: exit-code semantics ---
# All jobs produce a verdict (one is Issues Found) -> batch exits 0.
( BATCH_DISPATCH_SH="$MUX_STUB"; . "$LIB"; MAX_PARALLEL=4; batch_init
  batch_add "A-okay"   okay
  batch_add "B-issues" issues
  batch_run ) >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "all-verdict batch (incl Issues Found) exits 0" \
  || bad "all-verdict batch exits 0" "rc=$?"

# One job is ERROR (no verdict + nonzero) -> batch exits nonzero.
( BATCH_DISPATCH_SH="$MUX_STUB"; . "$LIB"; MAX_PARALLEL=4; batch_init
  batch_add "A-okay" okay
  batch_add "C-err"  err
  batch_run ) >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "batch with an ERROR job exits nonzero" \
  || bad "batch with an ERROR job exits nonzero" "rc=$?"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `batch_run` currently always `return 0`, so the ERROR case wrongly exits 0. The second assertion reports `bad`. Output ends with `13 passed, 1 failed`.

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
Expected: PASS — both exit-code assertions pass. Output ends with `15 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/review-batch-lib.sh scripts/review-batch-lib.test.sh
git commit -m "feat: return nonzero exit only when a job is a tool ERROR"
```

---

### Task 5: shutdown trap (process-group best-effort + reap + rm temp)

**Files:**
- Modify: `scripts/review-batch-lib.sh`
- Test: `scripts/review-batch-lib.test.sh`

Install a `trap` on EXIT/INT/TERM that: stops launching new jobs, best-effort kills each job's process group (`set -m` in the job subshell to get a distinct pgid; `kill -- -<pgid>` TERM then KILL after a short timeout), `wait`/reaps, removes the FIFO, and `rm -rf`s the temp dir. **Honest weak fallback:** if true pgroup kill isn't available, only the direct child PID is signaled and a companion grandchild may briefly survive — but its output lands in the already-removed temp dir and its companion job-id is unique, so it cannot corrupt a retry. The grandchild test asserts the strong guarantee where possible, else the documented weaker isolation.

- [ ] **Step 1: Write the failing tests (temp gone after run; grandchild killed or isolated)**

Append before the final lines of `scripts/review-batch-lib.test.sh`:

```bash
# --- Task 5: shutdown trap cleans temp + best-effort kills the job tree ---
# 5a: after a normal run, no review-batch.* temp dirs linger from this run.
before_dirs="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
( BATCH_DISPATCH_SH="$OKAY_STUB"; . "$LIB"; MAX_PARALLEL=2; batch_init
  batch_add "A" ; batch_add "B"
  batch_run ) >/dev/null 2>&1
after_dirs="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$after_dirs" -le "$before_dirs" ] \
  && ok "temp dir removed after normal run" \
  || bad "temp dir removed after normal run" "before=$before_dirs after=$after_dirs"

# 5b: a stub that spawns a grandchild which writes a marker after a delay; after we
# INT the batch, EITHER the grandchild was killed (marker absent = strong guarantee)
# OR the documented weak fallback holds (marker lands in the deleted temp, never in a
# fresh retry). We assert the marker does NOT appear in a path the batch still owns.
MARK="$ROOT/grandchild.marker"; rm -f "$MARK"
GC_STUB="$ROOT/gc/dispatch.sh"
write_stub "$GC_STUB" \
  '( sleep 1; echo alive > "'"$MARK"'" ) &' \
  'sleep 2' \
  'echo "Status: OKAY"'
( BATCH_DISPATCH_SH="$GC_STUB"; . "$LIB"; MAX_PARALLEL=1; batch_init
  batch_add "slow"
  batch_run ) >/dev/null 2>&1 &
BATCH_PID=$!
sleep 0.4
kill -INT "$BATCH_PID" 2>/dev/null
wait "$BATCH_PID" 2>/dev/null
sleep 1.2   # past the grandchild's 1s timer
# Strong-guarantee platforms: marker absent. Weak-fallback: marker may exist but the
# batch's temp dir is already gone, so a retry is unaffected. Either way, no temp dir
# from this run remains.
after_int="$(ls -d "${TMPDIR:-/tmp}"/review-batch.* 2>/dev/null | wc -l | tr -d ' ')"
[ "$after_int" -le "$before_dirs" ] \
  && ok "INT leaves no temp dir (stale grandchild cannot reach a retry's temp)" \
  || bad "INT leaves no temp dir" "after_int=$after_int before=$before_dirs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — there is no EXIT/INT/TERM trap, so an INT-interrupted run leaves its `review-batch.*` temp dir behind (and never signals the job group). The 5b assertion reports `bad`. Output ends with `16 passed, 1 failed`.

- [ ] **Step 3: Implement the shutdown trap + per-job process groups**

In `scripts/review-batch-lib.sh`, replace the entire `batch_run` function with this version (adds `_BATCH_TMP`/`_BATCH_PIDS`/`_BATCH_PGIDS` state, `_batch_shutdown`, the trap, `set -m` job subshells, and pgid capture):

```bash
# Shutdown: stop launching, best-effort kill each job's process group (TERM then KILL),
# reap, then remove the temp dir. Honest weak fallback: on platforms where a distinct
# process group per job is unavailable, only the direct child PID is signaled and a
# companion grandchild may briefly survive — but its output went to the (now-removed)
# temp dir and its companion job-id is unique, so it cannot corrupt a retry.
_batch_shutdown() {
  local p
  if [ "${#_BATCH_PGIDS[@]:-0}" -gt 0 ]; then
    for p in "${_BATCH_PGIDS[@]}"; do
      [ -n "$p" ] && kill -TERM "-$p" 2>/dev/null
    done
  fi
  if [ "${#_BATCH_PIDS[@]:-0}" -gt 0 ]; then
    for p in "${_BATCH_PIDS[@]}"; do
      [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
    done
  fi
  # Brief grace, then hard kill any survivors.
  local waited=0
  while [ "$waited" -lt 10 ]; do
    local alive=0
    for p in "${_BATCH_PIDS[@]:-}"; do
      [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1; waited=$((waited+1))
  done
  for p in "${_BATCH_PGIDS[@]:-}"; do [ -n "$p" ] && kill -KILL "-$p" 2>/dev/null; done
  for p in "${_BATCH_PIDS[@]:-}";  do [ -n "$p" ] && kill -KILL "$p"  2>/dev/null; done
  wait 2>/dev/null
  [ -n "${_BATCH_TMP:-}" ] && rm -rf "$_BATCH_TMP"
  _BATCH_TMP=""
}

batch_run() {
  : "${MAX_PARALLEL:=5}"
  _batch_validate_max_parallel || return 1

  _BATCH_PIDS=()
  _BATCH_PGIDS=()
  _BATCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-batch.XXXXXX")"
  local tmp="$_BATCH_TMP" fifo="$_BATCH_TMP/tokens"
  mkfifo "$fifo"
  exec 9<>"$fifo"
  trap '_batch_shutdown' EXIT INT TERM

  local t
  for ((t=0; t<MAX_PARALLEL; t++)); do printf '\n' >&9; done

  local i pid
  for i in "${!_BATCH_LABELS[@]}"; do
    read -r -u 9 _token
    (
      # set -m gives this subshell its own process group; record its pgid so shutdown
      # can signal the whole tree (dispatch.sh + node companion). Weak-fallback
      # platforms simply leave pgid unusable; the direct PID is still signaled.
      set -m 2>/dev/null || true
      eval "set -- ${_BATCH_ARGV[$i]}"
      "$BATCH_DISPATCH_SH" "$@" > "$tmp/$i.out" 2> "$tmp/$i.err"
      printf '%s' "$?" > "$tmp/$i.rc"
      printf '\n' >&9
    ) &
    pid=$!
    _BATCH_PIDS+=("$pid")
    _BATCH_PGIDS+=("$pid")   # with job control the bg subshell's pid == its pgid
  done
  wait
  exec 9>&-
  trap - EXIT INT TERM

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

  rm -rf "$tmp"
  _BATCH_TMP=""
  return "$rc_all"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: PASS — the normal run leaves no temp dir, and the INT-interrupted run reaps + removes its temp dir (strong-guarantee platforms also kill the grandchild). Output ends with `18 passed, 0 failed`.

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
# --- Task 6: review-brainstorm.sh wrapper argv assembly ---
BRAINSTORM="$HERE/review-brainstorm.sh"
PROOT="$ROOT/plugin"   # fixture PLUGIN_ROOT
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
  ok "review-brainstorm: structural-completeness argv matches spec"
else bad "review-brainstorm: structural-completeness argv" "$T6"; fi
# design-soundness: adversarial --base <SPEC_BASE> --focus <root>/.../adversarial-spec-review-focus.md
if printf '%s\n' "$T6" | grep -q '^## design-soundness$' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:adversarial' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:--base' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:SPECBASE' \
   && printf '%s\n' "$T6" | grep -qx 'ARG:--focus' \
   && printf '%s\n' "$T6" | grep -qx "ARG:$PROOT/skills/brainstorming/adversarial-spec-review-focus.md"; then
  ok "review-brainstorm: design-soundness argv matches spec"
else bad "review-brainstorm: design-soundness argv" "$T6"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-brainstorm.sh` does not exist, so `bash "$BRAINSTORM" ...` errors and `T6` is empty. Both assertions report `bad`. Output ends with `18 passed, 2 failed`.

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

SPEC=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)         SPEC="$2"; shift 2 ;;
    --base)         BASE="$2"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
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
Expected: PASS — both reviewer argv assertions pass. Output ends with `20 passed, 0 failed`.

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
# --- Task 7: review-plan.sh wrapper argv assembly ---
PLAN_W="$HERE/review-plan.sh"
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
  ok "review-plan: per-task Task 1 argv matches spec"
else bad "review-plan: per-task Task 1 argv" "$T7"; fi
printf '%s\n' "$T7" | grep -q '^## per-task Task 3$' \
  && ok "review-plan: second per-task job registered" \
  || bad "review-plan: second per-task job registered" "$T7"
# coverage-verifier job
if printf '%s\n' "$T7" | grep -q '^## coverage-verifier$' \
   && printf '%s\n' "$T7" | grep -qx "ARG:$PROOT/skills/writing-plans/coverage-verifier-prompt.md"; then
  ok "review-plan: coverage-verifier argv matches spec"
else bad "review-plan: coverage-verifier argv" "$T7"; fi
# require at least one --task or --coverage
( BATCH_DISPATCH_SH="$ECHO_STUB" PLUGIN_ROOT="$PROOT" \
  bash "$PLAN_W" --plan docs/plans/x.md --spec docs/specs/x.md ) >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "review-plan: no --task/--coverage fails fast" \
  || bad "review-plan: no --task/--coverage fails fast" "rc=0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-plan.sh` does not exist. All four new assertions report `bad`. Output ends with `20 passed, 4 failed`.

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

PLAN=""; SPEC=""; COVERAGE=0
TASKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         PLAN="$2"; shift 2 ;;
    --spec)         SPEC="$2"; shift 2 ;;
    --task)         TASKS+=("$2"); shift 2 ;;
    --coverage)     COVERAGE=1; shift ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
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
Expected: PASS — all four assertions pass. Output ends with `24 passed, 0 failed`.

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
# --- Task 8: review-impl.sh wrapper argv assembly ---
IMPL_W="$HERE/review-impl.sh"
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
  ok "review-impl: spec-compliance argv matches spec"
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
  ok "review-impl: code-quality argv matches spec"
else bad "review-impl: code-quality argv" "$T8"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/review-batch-lib.test.sh`
Expected: FAIL — `review-impl.sh` does not exist. The three new assertions report `bad`. Output ends with `24 passed, 3 failed`.

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

PLAN=""; TASK=""; TASK_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         PLAN="$2"; shift 2 ;;
    --task)         TASK="$2"; shift 2 ;;
    --task-base)    TASK_BASE="$2"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="$2"; shift 2 ;;
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
Expected: PASS — all three assertions pass. Output ends with `27 passed, 0 failed`.

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

Run: `grep -c 'inherently not diff/test-verifiable' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected (before edit): `0` — the new rule is absent.

- [ ] **Step 2: Apply the edits**

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

There is no implementer report to read. The implementation may be incomplete,
inaccurate, or optimistic. You MUST verify everything independently from the diff.

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

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -L REPORT_FILE_PATH skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: prints `skills/subagent-driven-development/spec-reviewer-prompt.md` (the file no longer contains `REPORT_FILE_PATH`, so `grep -L` lists it).

Run: `grep -c 'inherently not diff/test-verifiable' skills/subagent-driven-development/spec-reviewer-prompt.md` (note: match the rendered text)
Expected: `1`.

Run: `grep -c 'git diff \[TASK_BASE\]\.\.HEAD' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: ≥ `2` (diff range preserved; no `[TASK_HEAD]` introduced).

Run: `grep -c 'TASK_HEAD' skills/subagent-driven-development/spec-reviewer-prompt.md`
Expected: `0`.

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

Replace the two-background-call dispatch (the "Parallel dispatch per round" + "Dispatch mechanism" + the two separate `dispatch.sh` blocks) with a single `review-brainstorm.sh` call plus the explicit caller control-flow from spec §7 (read stdout on ANY exit code; classify from `=== Summary ===`; ERROR → rerun whole wrapper; findings → fix + re-review).

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -c 'review-brainstorm.sh' skills/brainstorming/SKILL.md`
Expected (before edit): `0`.

- [ ] **Step 2: Apply the edit**

Replace the block that begins with `**Parallel dispatch per round:**` and ends with the Design Soundness `dispatch.sh adversarial` fenced code block (lines from `**Parallel dispatch per round:**` through the closing ``` of the adversarial block) with:

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
   (design-soundness), or `ERROR (tool failed, ...)`.
3. **If any reviewer is ERROR** → **re-run the entire `review-brainstorm.sh` call** (same
   arguments). Do not treat ERROR as a review failure and do not discard stdout.
4. **Otherwise** apply the round loop: if either reviewer reports a finding, fix ALL findings,
   commit, and re-run the whole wrapper next round; when structural-completeness is
   `Status: OKAY` AND design-soundness is `Verdict: approve` in the same round, the loop ends.
````

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -c 'review-brainstorm.sh' skills/brainstorming/SKILL.md`
Expected: ≥ `2` (the command block + the prose reference).

Run: `grep -c 'run_in_background' skills/brainstorming/SKILL.md`
Expected: the count should be smaller than before — verify the "Parallel dispatch per round" reviewer section no longer instructs separate background calls. (Run before and after; the rewritten section drops its `run_in_background` instructions.)

Run: `grep -c '=== Summary ===' skills/brainstorming/SKILL.md`
Expected: ≥ `1`.

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

Replace the per-Task + Coverage background dispatch (the "Dispatch mechanism" section with its two `dispatch.sh task` blocks and the surrounding "separate run_in_background Bash call" instructions) with a single `review-plan.sh` call (multiple `--task`, optional `--coverage`) plus the spec §7 caller control-flow.

- [ ] **Step 1: Write the verify check (expected to fail before the edit)**

Run: `grep -c 'review-plan.sh' skills/writing-plans/SKILL.md`
Expected (before edit): `0`.

- [ ] **Step 2: Apply the edit**

Replace the entire `### Dispatch mechanism (shared `dispatch.sh`)` subsection (from its heading through the Coverage Verifier `dispatch.sh task` fenced block) with:

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
2. Classify each reviewer from its Summary line: `Status: OKAY` / `Status: Issues Found`, or
   `ERROR (tool failed, ...)`.
3. **If any reviewer is ERROR** → **re-run the entire `review-plan.sh` call** with the same
   `--task`/`--coverage` set. Do not treat ERROR as a review failure and do not discard stdout.
4. **Otherwise** apply the unified re-run policy below: fix all issues and gaps, commit, and
   re-run next round with the next round's active `--task`/`--coverage` set; the loop ends
   when every active reviewer returns `Status: OKAY` in a single round.
````

- [ ] **Step 3: Run the verify checks (expected to pass after the edit)**

Run: `grep -c 'review-plan.sh' skills/writing-plans/SKILL.md`
Expected: ≥ `2`.

Run: `grep -c '=== Summary ===' skills/writing-plans/SKILL.md`
Expected: ≥ `1`.

Run: `grep -c 'separate.*run_in_background.*Bash call' skills/writing-plans/SKILL.md`
Expected: `0` in the rewritten Dispatch mechanism section (the per-reviewer separate-background-call instruction is gone). Other parts of the file that still mention `run_in_background` in the Round Loop prose may be updated for consistency but the Dispatch mechanism no longer instructs separate calls.

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

Replace the two-stage per-task review (the "Spec-compliance reviewer" + "Code-quality reviewer" subsections and the report-file `mktemp`→`--report-file`→`rm` wiring) with a single `review-impl.sh` call (spec + code-quality parallel, §5.3 contract). REMOVE every mention of the report-file wiring (incl. the process diagram's `--report-file` node, the Example Workflow lines, and the Sidecar files line). Keep the final adversarial merge gate unchanged. Add the §7 caller control-flow.

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
do not run verbatim. **There is no report file** — the spec-compliance reviewer verifies
directly from `git diff <TASK_BASE>..HEAD`, so no `mktemp`/`--report-file`/`rm` is needed:

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
   `Status: OKAY` / `Status: Issues Found`; code-quality from its prose (a blocking-severity
   defect = a finding); or `ERROR (tool failed, ...)`.
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
=== Summary ===
- spec-compliance: Status: OKAY
- code-quality: (prose — 見全文)  [prose: Clean implementation. No blocking issues found.]
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
=== Summary ===
- spec-compliance: Status: Issues Found
- code-quality: (prose — 見全文)
  spec-compliance:
    - src/recovery.ts:47 — Missing progress reporting (spec says "report every 100 items")
      Fix: [concrete patch provided]
    - src/recovery.ts:112 — Extra --json flag not in spec
      Fix: [concrete removal patch provided]
  code-quality prose: src/recovery.ts:47 uses magic number 100 — should be a named constant.

[Implementer applies ALL findings from both reviewers in one pass, re-commits]

[Re-run batched review: review-impl.sh --task "Task 2" --task-base def5678]
=== Summary ===
- spec-compliance: Status: OKAY
- code-quality: (prose — 見全文)  [prose: Clean. No issues.]
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

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "docs: rewrite per-task review to single review-impl.sh, drop report-file wiring"
```

---

## Final verification

After Task 12, run the full engine test suite once more and confirm it is green:

Run: `bash scripts/review-batch-lib.test.sh`
Expected: `27 passed, 0 failed` and exit 0.

Confirm `dispatch.sh` and its tests were never touched:

Run: `git diff --name-only <IMPL_BASE>..HEAD | grep -E 'scripts/dispatch\.(sh|test\.sh)$'`
Expected: prints nothing.
