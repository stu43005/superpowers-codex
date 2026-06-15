# Plan Document Reviewer Prompt Template

Use this template when dispatching a per-Task plan document reviewer via the codex companion.

**Purpose:** Verify that one specific Task in the plan is complete, internally consistent, and ready for an implementer to execute without ambiguity. When reviewing a Task that was edited this round, also guard the integration seams: check that the changed Task's types, naming, and interfaces remain consistent with all sibling Tasks — catching "a change in Task A breaks already-passed Task B" without needing to re-review B directly.

**Dispatch:** One codex `task` call per Task (read-only). The caller loops — re-dispatching for a Task — until this reviewer returns `Status: OKAY` for that Task.

## How to Dispatch

> **Run this block as-is — do not pre-verify the companion.** The path-resolution step
> below already locates the companion (`ls … | sort -V | tail -1`, with a marketplace
> fallback) and exits with a clear error if it is absent. Do NOT separately `ls`/`find`
> for the companion, run `node "$CODEX_COMPANION" --help`, or grep the companion source
> before dispatching. The `task --prompt-file <path>` flag IS supported — the companion
> reads `options["prompt-file"]` and lists `prompt-file` among its value options — even
> though `--help` does not document it. This is verified, not a guess, so no
> re-verification is needed.
>
> **`--prompt-file` takes `$PROMPT_FILE` (the temp file the block below writes) — NEVER
> this template document.** Passing this `.md` file (or any path under `skills/`) as
> `--prompt-file` feeds Codex these dispatch instructions instead of the reviewer prompt.
> `task` has **no `--wait` flag** (that belongs to `review`/`adversarial-review`); the Task
> text goes INSIDE the temp file (paste it into the heredoc body) and the spec path is
> injected via the `sed` substitution below — never as inline arguments to `task`.

```bash
# Resolve codex companion path
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi

# Paste the Task text into the [PASTE ...] placeholders in the heredoc body below.
# Set SPEC_FILE to the spec under review; [SPEC_FILE_PATH] is substituted with it before dispatch.
SPEC_FILE="docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md"
PROMPT_FILE="$(mktemp)"
cat > "$PROMPT_FILE" <<'PROMPT'
You are an independent plan Task reviewer executed by the codex companion. You must use
rigorous judgment. Do not approve a Task that has real problems just to avoid friction.

**Task to review:** [PASTE THE FULL TEXT OF THE SINGLE TASK HERE]

**Sibling Tasks (all other Tasks in the plan — for cross-Task consistency checking):**
[PASTE THE FULL TEXT OF ALL OTHER TASKS HERE]

**Spec file path:** [SPEC_FILE_PATH]
Read the spec file in full before proceeding.

## What to Check

Review the Task under review against ALL seven criteria below. Flag any issue that would
cause an implementer to build the wrong thing, get stuck, or produce inconsistent code.

**1. Spec Coverage**
Does this Task correctly implement its corresponding spec requirement(s)?
Map every step back to a spec section. Flag any step that contradicts the spec
or any spec requirement assigned to this Task that is not addressed.

**2. Placeholder Scan**
Search for vague filler that leaves real decisions to the implementer:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases" (without showing the actual code)
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (the implementer may be executing Tasks out of order)
- Any step that describes *what* to do without showing *how* (code blocks are required for code steps)
- References to types, functions, or methods not defined anywhere in the plan

**3. Type Consistency and Cross-Task Integration Seams**
Are types, method signatures, and property names consistent between this Task and all
sibling Tasks? A function named `clearLayers()` in this Task but `clearFullLayers()` in
another Task is a latent bug. Flag every mismatch.

When this Task was edited (i.e., you are re-reviewing it after a fix), you MUST
additionally check whether the edit introduced any inconsistency or broken integration
seam with the sibling Tasks provided in context. This covers the case where a change
in this Task could break an already-passed sibling Task — you are responsible for
catching that here so sibling Tasks do not need to be re-reviewed solely for this reason.
Flag every such cross-Task breakage found.

**4. Code Completeness**
Every step that changes or creates code must contain the actual code — not a
description of what the code should do. A step like "implement the parser" with
no code block is a plan failure.

**5. Command Accuracy**
Every command must be complete and correct (right flags, right paths, right tool).
Expected output must be plausible and specific. "Expected: PASS" is acceptable;
"Expected: it works" is not.

**6. Document Reference Leak**
Code blocks and inline code comments must not reference the spec or plan documents
themselves. Examples of forbidden references:
- "per design spec §1-4"
- "see plan Task 2"
- "as described in the spec"
- "according to the implementation plan"
Code must be self-explanatory. Remove every such reference.

**7. Pre-Implementation Research Task Leak**
The plan must not contain steps or tasks that merely verify third-party library or
API behavior before implementation begins. Such research must happen *before* the
plan is written — deferring it to the implementer is a plan failure.

Forbidden examples:
- "Verify that library X's Y method accepts Z parameter"
- "Confirm the semantics of Z API call"
- "Check whether package W supports feature V"

**Distinguishing rule:** If the question can be answered by reading docs or source
code right now, it is pre-implementation research and is forbidden in the plan.
If it can only be answered by running against a real system after implementation
(e.g. `getIndexes()`, `EXPLAIN`, slow-query log, APM metrics, smoke tests,
migration before/after comparison), it is legitimate operational verification and
must NOT be removed.

## Calibration

Only flag issues that would cause real problems during implementation.
Minor wording preferences and style suggestions are not issues.
Approve a Task only when all seven criteria pass AND no cross-Task seam breakage
was found.

## Output Format

### Task [N] Review

**Issues (if any):**
- [Criterion]: [specific issue at Step X] — [why it matters for implementation]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement that do not constitute blockers]

Your final line MUST be exactly one of:
Status: OKAY
Status: Issues Found
PROMPT
# Heredoc is literal (<<'PROMPT'); inject the real spec path into the temp file.
sed -i "s#\[SPEC_FILE_PATH\]#${SPEC_FILE}#g" "$PROMPT_FILE"
node "$CODEX_COMPANION" task --prompt-file "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

**Reviewer returns:** A final line of `Status: OKAY` or `Status: Issues Found`. The parent parses this line to drive the loop.

**Parallel dispatch within a round:** Each per-Task reviewer for Tasks active in the current round is launched as a separate Bash call with `run_in_background: true`. When a backgrounded dispatch finishes, Claude Code notifies you automatically — do NOT poll BashOutput in a loop or otherwise wait for the output to have a value. Wait for each completion notification, then read that task's output once.
