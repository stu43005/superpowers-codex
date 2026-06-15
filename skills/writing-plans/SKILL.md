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

After writing and saving the complete plan, do **not** perform an inline self-review. Instead, dispatch reviewers via the **codex companion** (`codex-companion.mjs`). There are two reviewer roles:

- **Per-Task reviewer (reviewer 3):** reviews one Task at a time using `plan-document-reviewer-prompt.md`, dispatched via `node <companion> task` (read-only).
- **Coverage Verifier (reviewer 4):** reviews the whole plan against the whole spec using `coverage-verifier-prompt.md`, dispatched via `node <companion> task` (read-only).

If the codex companion is not installed, stop and ask the user to run `/codex:setup`. Do not fall back to inline self-review or any other substitute.

### Unified Re-run Policy

Which reviewers run in each round is governed by these three principles:

1. **Changed content must be re-reviewed.** Any Task that was edited this round (to fix an issue or fill a coverage gap) re-enters per-Task review in the next round. A newly added Task enters per-Task review for the first time. A Task that was not touched this round and already holds `Status: OKAY` drops out — it does not run again.

2. **The Per-Task reviewer guards cross-Task seams.** When reviewing a changed Task A, the reviewer is given the full text of all sibling Tasks as context and must check whether A's changes introduced any type, naming, or integration inconsistency with those siblings. This means "a change in A could break already-passed B" is caught by A's reviewer — B does not need to be re-reviewed for that reason alone.

3. **The Coverage Verifier re-runs only when its own gaps were fixed.** If the Coverage Verifier returned `Status: OKAY`, it drops out for all subsequent rounds. It does NOT re-run merely because some Task was changed — cross-Task consistency is the Per-Task reviewer's responsibility (principle 2). It re-runs only if it previously reported coverage gaps that were then addressed.

Both cases of "fix A breaks B" are therefore covered:
- If B's content was edited → B re-enters per-Task review (principle 1).
- If B's content was not edited but A's change could break B → A's reviewer catches it (principle 2).

### Per-Task Review

For **each Task** in the plan, dispatch a per-Task reviewer using the template in `./plan-document-reviewer-prompt.md`. Each reviewer call receives the full text of the single Task under review plus the full text of all sibling Tasks as context.

A Task that has not yet received `Status: OKAY` gets a reviewer dispatched each round. A Task drops out of the loop once its reviewer reports `Status: OKAY` and its content is not edited again.

### Coverage Verifier

In **addition** to the per-Task reviews, dispatch one Coverage Verifier each round using the template in `./coverage-verifier-prompt.md`. It reads the whole plan file and whole spec file (read-only) and compares them globally.

If it returns coverage gaps, fill every gap: add Tasks, strengthen existing Tasks, or amend the spec. Any newly added or substantially changed Task re-enters per-Task review in the next round. The Coverage Verifier re-runs next round only if gaps were fixed this round.

### The Round Loop

Per-Task reviewers and the Coverage Verifier are dispatched **in parallel** within a round using separate Bash calls with `run_in_background: true`. Do not wait for all per-Task reviews to finish before launching the Coverage Verifier. When a backgrounded dispatch finishes, Claude Code notifies you automatically — do NOT poll BashOutput in a loop or otherwise wait for the output to have a value. Wait for each completion notification, then read that task's output once. Once all results are in, fix all issues and gaps together, then start the next round.

The invocation blocks in the prompt templates are canonical and self-contained: each one already resolves the companion path (with a marketplace fallback) and fails loudly if it is absent. Run them as written — do NOT pre-probe the companion with `--help`, `ls`/`find`, or source greps before dispatching. In particular, `task --prompt-file <path>` is supported even though `--help` does not list it (verified in the companion source); treat it as established, not a guess. Here `<path>` is the temp file each template writes its reviewer prompt to — NEVER the template `.md` itself — and `task` takes no `--wait` flag (the plan/spec paths are substituted into that temp file, not passed inline).

The loop ends when, within a single round, every active Per-Task reviewer returns `Status: OKAY` and the Coverage Verifier (if still active) returns `Status: OKAY`.

```
# Unified re-run policy:
#   - active_tasks: Tasks under review this round (changed or never yet OKAY)
#   - coverage_active: True until Coverage Verifier reports OKAY with no gaps fixed this round
active_tasks = all plan tasks   # first round: every task
coverage_active = True

while True:
    # Dispatch in parallel
    task_results = parallel(
        [dispatch_task_reviewer(task, sibling_tasks=all_other_tasks) for task in active_tasks],
        dispatch_coverage_verifier(spec_file, plan_file) if coverage_active else [],
    )

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
2. Re-run the per-Task reviewer for every **affected Task** (dispatched in parallel), passing sibling Task context.
3. Re-run the Coverage Verifier over the whole plan vs. the whole spec (edits can introduce new coverage gaps).
4. Apply the unified re-run policy: loop each reviewer until `Status: OKAY`, with zero tolerance — nothing may be deferred.
5. Commit the fixed plan.
6. Report the result back to the user and **wait for their next reply**.

Only leave this gate once the user **explicitly approves** (e.g. "OK", "looks good", "start implementation"). Do not self-approve or assume approval from silence.

## Execution Handoff

After the user explicitly approves the plan:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Ready to start implementation? (using Subagent-Driven Development)"**

On confirmation, invoke the **REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`**. No alternative execution method is offered.
