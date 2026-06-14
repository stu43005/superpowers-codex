# Code Quality Reviewer — Codex Native Review Dispatch

Run after spec compliance review (reviewer 5) passes for a task. Dispatches reviewer 6 via codex companion native `review` command with `--base <TASK_BASE>`.

**Purpose:** Let Codex's native reviewer assess code quality and surface bugs or correctness problems in the task's diff. No custom quality checklist — the native reviewer owns that judgment.

**Only dispatch after spec compliance review returns `Status: OKAY`.**

---

## Step 1: Retrieve TASK_BASE

`TASK_BASE` must have been captured (as `git rev-parse HEAD`) at the moment before the implementer for this task started. Retrieve it from your task-tracking state. This SHA must be a direct ancestor of the current HEAD.

## Step 2: Locate codex companion

```bash
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi
```

## Step 3: Run native review

Substitute `[TASK_BASE]` with the actual SHA captured in Step 1.

```bash
node "$CODEX_COMPANION" review --base [TASK_BASE] --wait
```

The `--base` flag instructs the companion to diff `git diff $(git merge-base HEAD [TASK_BASE])..HEAD`. Because `TASK_BASE` is a direct ancestor of HEAD, the merge-base equals `TASK_BASE`, so the reviewed diff is exactly the task's implementation commits.

## Step 4: Interpret the prose output (Mechanism C)

**Important:** The native `review` command does NOT emit a structured `Verdict:` line or `approve`/`needs-attention` output. It returns free-form prose from the Codex reviewer. Do NOT attempt to parse a `Verdict:` line here — that field only exists for `adversarial-review`.

You (the parent agent) interpret the prose:

- **If the prose reports any blocking-severity defect** — a bug, a clear correctness issue, a significant code quality problem that would prevent a confident merge — treat this as **Issues Found**:
  1. Extract the file:line reference(s) and recommendation(s) from the prose.
  2. Dispatch the implementer subagent with the specific findings and ask them to fix all blocking issues.
  3. Re-run this reviewer from Step 1 after fixes are committed.
  4. Repeat until no blocking findings remain.

- **If the prose reports no significant issues** (or only minor style observations that do not affect correctness or quality) — treat this as **OKAY**: mark the code quality gate as passed and proceed to the next task (or to the final reviewer if all tasks are complete).

**Severity calibration:** A "blocking" finding is one that a reasonable senior engineer would require fixed before merging — bugs, data-loss risks, broken error handling, security issues, missing critical test coverage. Style preferences and non-blocking suggestions do not trigger a re-review loop.

**Do not ask the user** whether to re-run or proceed. This loop runs automatically until the quality gate clears.
