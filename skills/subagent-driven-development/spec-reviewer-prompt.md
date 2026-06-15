# Spec Compliance Reviewer — Codex Task Dispatch

Run after each implementer subagent completes a task. Dispatches reviewer 5 via codex companion `task` (read-only). No `--write` flag — Codex reads files and git history only.

**Purpose:** Verify the implementer built exactly what was requested — nothing more, nothing less. Do NOT trust the implementer's report; read the actual code.

**Only dispatch after implementer reports DONE or DONE_WITH_CONCERNS.**

---

## Step 1: Resolve TASK_BASE

`TASK_BASE` must have been captured (as `git rev-parse HEAD`) at the moment before the implementer for this task started. Retrieve it from your task-tracking state.

## Step 2: Locate codex companion

> **Run this block as-is — do not pre-verify the companion.** The block below already
> locates the companion (`ls … | sort -V | tail -1`, with a marketplace fallback) and
> exits with a clear error if it is absent. Do NOT separately `ls`/`find` for the
> companion, run `node "$CODEX_COMPANION" --help`, or grep the companion source before
> dispatching. The `task --prompt-file <path>` flag used in Step 3 IS supported — the
> companion reads `options["prompt-file"]` and lists `prompt-file` among its value
> options — even though `--help` does not document it. This is verified, not a guess, so
> no re-verification is needed.
>
> **In Step 3, `--prompt-file` takes `$PROMPT_FILE` (the temp file that block writes) —
> NEVER this template document.** Passing this `.md` file (or any path under `skills/`) as
> `--prompt-file` feeds Codex these dispatch instructions instead of the reviewer prompt.
> `task` has **no `--wait` flag** (that belongs to `review`/`adversarial-review`); the task
> text, base SHA, and report go INSIDE the temp file (substitute the placeholders in the
> heredoc body per Step 3), never as inline arguments to `task`.

```bash
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi
```

## Step 3: Write the review prompt and dispatch

Substitute `[TASK_BASE]` with the actual SHA captured in Step 1, `[FULL TEXT of task requirements]` with the verbatim task text from the plan, and `[From implementer's report]` with the implementer's summary.

```bash
PROMPT_FILE="$(mktemp)"
cat > "$PROMPT_FILE" <<'PROMPT'
You are reviewing whether an implementation matches its specification.

## What Was Requested

[FULL TEXT of task requirements]

## What Implementer Claims They Built

[From implementer's report]

## CRITICAL: Do Not Trust the Report

The implementer may have finished quickly. Their report may be incomplete,
inaccurate, or optimistic. You MUST verify everything independently.

**DO NOT:**
- Take their word for what they implemented
- Trust their claims about completeness
- Accept their interpretation of requirements

**DO:**
- Run `git diff [TASK_BASE]..HEAD` to read the actual code changes
- Compare actual implementation to requirements line by line
- Check for missing pieces they claimed to implement
- Look for extra features they didn't mention

## How to Read the Implementation

Run this git command yourself to see exactly what was changed:

git diff [TASK_BASE]..HEAD

This is a literal two-dot range covering all commits since that base — read every file changed and every line added or removed.

## Your Job

Read the implementation code and verify:

**Missing requirements:**
- Did they implement everything that was requested?
- Are there requirements they skipped or missed?
- Did they claim something works but didn't actually implement it?

**Extra/unneeded work:**
- Did they build things that weren't requested?
- Did they over-engineer or add unnecessary features?
- Did they add "nice to haves" that weren't in spec?

**Misunderstandings:**
- Did they interpret requirements differently than intended?
- Did they solve the wrong problem?
- Did they implement the right feature but the wrong way?

**Verify by reading code, not by trusting the report.**

## Issue Reporting Requirements

> **MANDATORY — zero exceptions:** For every issue you find, you MUST provide ALL of the following. Omitting either item is a reviewer error.
>
> 1. **Precise location** — the exact file path and line number(s) where the problem occurs (e.g. `src/foo/bar.ts:42`).
> 2. **Concrete fix** — a complete patch or directly-applicable replacement code that resolves the issue. You MUST NOT describe what should change in prose without also supplying actual code. "This function should validate X" is forbidden; a diff or replacement snippet is required.

## Output Contract

Your final output line MUST be exactly one of:

Status: OKAY
(if the implementation is fully spec-compliant after code inspection)

Status: Issues Found
(followed by each issue with its exact file:line location AND a concrete code fix — never prose-only descriptions)

No other final line format is accepted.
PROMPT
node "$CODEX_COMPANION" task --prompt-file "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

## Step 4: Interpret the result

Parse the **last `Status:` line** in Codex's output:

- `Status: OKAY` → spec compliance passes; proceed to code quality review (reviewer 6).
- `Status: Issues Found` → collect every issue (file:line + fix patch); dispatch the implementer subagent to apply all fixes; then re-run this reviewer from Step 1. Repeat until `Status: OKAY`.

**Zero tolerance:** Do not proceed to code quality review while any issue remains open.
