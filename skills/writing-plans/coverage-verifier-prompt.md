# Coverage Verifier Prompt Template

Use this template when dispatching a coverage verifier via the codex companion.

**Purpose:** Verify that the **whole plan** covers the **whole spec** — a global coverage check across all Tasks, not a per-Task review. This catches gaps that per-Task reviewers miss because they only see one Task at a time.

**Dispatch:** One codex `task` call (read-only), dispatched in parallel with the per-Task reviewers in each round. The caller loops — re-dispatching the Coverage Verifier — only if it returned coverage gaps that were then fixed. If it returned `Status: OKAY`, it drops out of subsequent rounds and does not re-run merely because some Task was changed (cross-Task consistency is the Per-Task reviewer's responsibility).

## How to Dispatch

```bash
# Resolve codex companion path
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi

PROMPT_FILE="$(mktemp)"
cat > "$PROMPT_FILE" <<'PROMPT'
You are an independent coverage verifier executed by the codex companion. You must use
rigorous judgment. Your job is to compare the ENTIRE plan against the ENTIRE spec and
identify anything in the spec that the plan fails to cover, silently changes, or weakens.

**Plan file path:** [PLAN_FILE_PATH]
**Spec file path:** [SPEC_FILE_PATH]

Read both files in full before proceeding.

## What to Check

**1. Spec Requirements — Item by Item**
List every functional requirement, described behavior, and acceptance criterion in
the spec. For each one, identify which Task(s) in the plan implement it. If a
requirement has no corresponding Task, list it as a coverage gap.

**2. Design Decisions — Item by Item**
List every design decision in the spec: architecture choices, data structures, API
shapes, error-handling strategy, dependency selections, performance constraints,
security requirements, compatibility constraints. For each one, confirm it is
realized in the plan. Flag anything that is:
- Missing entirely (no Task addresses it)
- Silently changed (the plan makes a different choice without acknowledging it)
- Weakened (the plan addresses it partially or makes it optional when the spec requires it)

**3. Implicit Requirements and Edge Conditions**
Identify conditions phrased in the spec with "should", "must", "need", "avoid",
"must not", or equivalent. Confirm each has a corresponding implementation step
or verification step in the plan. List any that do not.

**4. Cross-Task Integration**
Identify spec requirements that are split across multiple Tasks. Confirm there is
an integration point — a Task, step, or test — that actually connects them.
Example failure: Task A defines a type and Task B uses it, but no Task imports or
wires them together. List any disconnected splits.

**5. Out-of-Scope Content**
Identify any work in the plan that has no corresponding requirement in the spec
(scope creep). List each item so the user can decide whether to keep it.

## Calibration

Only flag issues that represent real gaps, contradictions, or scope creep.
Minor wording differences and stylistic choices between the spec and plan are not gaps.
Approve only when every spec requirement and design decision is accounted for.

## Output Format

### Coverage Verification

**Coverage Gaps (if any):**
- [Spec section / requirement]: not covered — [which Task should address it, or suggest a new Task]

**Design Decision Gaps (if any):**
- [Spec decision]: missing / changed / weakened — [details]

**Implicit Requirement Gaps (if any):**
- [Condition from spec]: no corresponding step in plan — [details]

**Cross-Task Integration Gaps (if any):**
- [Requirements split across Tasks X and Y]: missing integration point — [details]

**Out-of-Scope Content (informational, does not block approval):**
- [Plan Task / step]: not traceable to any spec requirement — [details]

Your final line MUST be exactly one of:
Status: OKAY
Status: Issues Found
PROMPT
node "$CODEX_COMPANION" task --prompt-file "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

**Reviewer returns:** A final line of `Status: OKAY` or `Status: Issues Found`. The parent parses this line to drive the loop.
