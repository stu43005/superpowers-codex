---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- DRY, YAGNI, TDD, frequent commits

## Mandatory Workflow Sequence

The only permitted order is:

```
brainstorming → spec → writing-plans → plan → implementation
```

You **must** have a written, reviewed, user-approved plan before a single line of implementation code is touched. Never skip or abbreviate the plan step because the task "seems simple" or "only touches one file." If you ever catch yourself writing implementation code without a plan, **stop immediately** and return to this skill first.

## Plan Review Loop

After writing and saving the complete plan, do **not** perform an inline self-review. Instead, dispatch all reviewers with ONE `review-plan.sh` call (see **Dispatch mechanism** below). There are two reviewer roles:

- **Per-Task reviewer:** reviews one Task at a time, registered by `review-plan.sh` as one `--task "Task N"` per active Task (read-only).
- **Coverage Verifier:** reviews the whole plan against the whole spec, registered by `review-plan.sh` via `--coverage` (read-only).

If the superpowers-codex plugin is not installed, stop and ask the user to run `/plugin install`. Do not fall back to inline self-review or any other substitute.

### Unified Re-run Policy

Which reviewers run in each round is governed by these three principles:

1. **Changed content must be re-reviewed.** Any Task that was edited this round (to fix an issue or fill a coverage gap) re-enters per-Task review in the next round. A newly added Task enters per-Task review for the first time. A Task that was not touched this round and already holds `Status: OKAY` drops out — it does not run again.

2. **The Per-Task reviewer guards cross-Task seams.** When reviewing a changed Task A, the reviewer reads the plan file and treats all other Tasks as sibling context (no Task text is pasted) and must check whether A's changes introduced any type, naming, or integration inconsistency with those siblings. This means "a change in A could break already-passed B" is caught by A's reviewer — B does not need to be re-reviewed for that reason alone.

3. **The Coverage Verifier re-runs only when its own gaps were fixed.** If the Coverage Verifier returned `Status: OKAY`, it drops out for all subsequent rounds. It does NOT re-run merely because some Task was changed — cross-Task consistency is the Per-Task reviewer's responsibility (principle 2). It re-runs only if it previously reported coverage gaps that were then addressed.

Both cases of "fix A breaks B" are therefore covered:
- If B's content was edited → B re-enters per-Task review (principle 1).
- If B's content was not edited but A's change could break B → A's reviewer catches it (principle 2).

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

Each `--task "Task N"` becomes a per-Task reviewer (label `per-task Task N`); the reviewer reads
the plan file and treats every other Task as sibling context (no Task text is pasted).
`--coverage` adds the Coverage Verifier over the whole plan vs. whole spec. Omit `--coverage` in
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
4. **If any reviewer's Summary line carries a `(tool exit N)` annotation** (a `Status:` was
   produced but the tool then exited nonzero), the result exists but its output may be incomplete:
   read that reviewer's full `## <label>` section and use judgment — re-run the whole wrapper if the
   output looks truncated, otherwise act on the result shown. Neither an automatic pass nor a forced
   rerun.
5. **Otherwise** apply the unified re-run policy below: fix all issues and gaps, commit, and
   re-run next round with the next round's active `--task`/`--coverage` set; the loop ends
   when every active reviewer returns `Status: OKAY` in a single round.

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
round the Coverage Verifier is active (it reviews the whole plan file and whole spec file,
read-only, comparing them globally).

If it returns coverage gaps, fill every gap: add Tasks, strengthen existing Tasks, or amend the
spec. Any newly added or substantially changed Task re-enters per-Task review next round (as a new
`--task`). Keep `--coverage` on next round only if gaps were fixed this round; otherwise omit it.

### The Round Loop

Per-Task reviewers and the Coverage Verifier all run **in parallel** within a round via ONE `review-plan.sh` call — pass every active Task as a `--task "Task N"` and add `--coverage` while the Coverage Verifier is active. The wrapper returns ALL reviewers' output on stdout in one shot; read its `=== Summary ===` on any exit code. Once you have parsed every reviewer's result, fix all issues and gaps together, then start the next round.

Use the **Dispatch mechanism** `review-plan.sh` invocation above exactly as written — do NOT pre-probe `review-plan.sh` with `--help`, `ls`/`find`, or source greps before dispatching.

The loop ends when, within a single round, every active Per-Task reviewer returns `Status: OKAY` and the Coverage Verifier (if still active) returns `Status: OKAY`.

```
# Unified re-run policy:
#   - active_tasks: Tasks under review this round (changed or never yet OKAY)
#   - coverage_active: True until Coverage Verifier reports OKAY with no gaps fixed this round
active_tasks = all plan tasks   # first round: every task
coverage_active = True

while True:
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
    gaps   = collect_gaps(task_results)

    if not issues and not gaps:
        break   # all active reviewers returned OKAY — done

    # Fix every issue and every gap (zero tolerance — nothing deferred)
    edited_tasks = fix_all_issues(issues)     # returns which Tasks were edited
    gap_tasks    = fix_all_gaps(gaps)         # may add new Tasks or edit existing ones
    coverage_had_gaps = bool(gaps)

    # Determine next round's active set per unified policy
    active_tasks = edited_tasks | gap_tasks | unresolved_tasks(task_results)
    # Principle 3: Coverage Verifier re-runs only if it raised gaps that were just fixed
    coverage_active = coverage_had_gaps
    # Tasks that were OKAY and untouched are excluded from active_tasks -> drop out
```

### Git Commit Discipline

- **Before the first review round:** commit the first version of the plan file.
- **After each round's fixes:** commit again with a message that identifies the round, e.g. `docs(plan): fix review round 2 - add missing migration task`.
- If the plan file is gitignored, skip the commit. **Never** use `git add -f` to force-add an ignored file.

## User Review Gate

After all active Per-Task reviewers and the Coverage Verifier report `Status: OKAY`, present the plan to the user for review.

If the user requests any changes:

1. Make the requested changes.
2. Re-run review with ONE `review-plan.sh` call: pass one `--task "Task N"` for every **affected Task** so each reviewer reads sibling Task context from the plan file, and add `--coverage` to also re-run the Coverage Verifier over the whole plan vs. the whole spec (edits can introduce new coverage gaps).
4. Apply the unified re-run policy: loop each reviewer until `Status: OKAY`, with zero tolerance — nothing may be deferred.
5. Commit the fixed plan.
6. Report the result back to the user and **wait for their next reply**.

Only leave this gate once the user **explicitly approves** (e.g. "OK", "looks good", "start implementation"). Do not self-approve or assume approval from silence.

## Execution Handoff

After the user explicitly approves the plan:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Ready to start implementation? (using Subagent-Driven Development)"**

On confirmation, invoke the **REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`**. No alternative execution method is offered.
