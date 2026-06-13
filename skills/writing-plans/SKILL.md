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

## Plan Review Loop (Subagents)

After writing and saving the complete plan, do **not** perform an inline self-review. Instead, dispatch **independent review subagents** — separately launched Agents, not a checklist you run yourself. All review subagents **must** use the **opus** model.

### Per-Task Review

For **each Task** in the plan, dispatch an independent review subagent using the template in `./plan-document-reviewer-prompt.md`. Each subagent reviews exactly one Task in isolation against the full spec.

Loop per Task until its subagent reports **OKAY**:

1. Dispatch the subagent for that Task.
2. If the subagent returns issues, fix **every single issue** (zero tolerance — nothing may be deferred).
3. Re-dispatch the subagent for the same Task.
4. Repeat until the subagent returns OKAY.

### Coverage Verifier

In **addition** to the per-Task reviews, dispatch **one Coverage Verifier subagent** (opus) using the template in `./coverage-verifier-prompt.md`. It compares the **whole plan** against the **whole spec** — not a single Task.

Loop until the Coverage Verifier reports **OKAY**:

1. Dispatch the Coverage Verifier.
2. If it returns coverage gaps, fill every gap: add Tasks, strengthen existing Tasks, or amend the spec. If filling a gap creates a new Task or substantially changes an existing one, re-run that Task's per-Task review loop before the next Coverage Verifier round.
3. Re-dispatch the Coverage Verifier.
4. Repeat until OKAY.

### Parallelism

Per-Task review subagents and the Coverage Verifier **may be dispatched in parallel** in the same round — you do not need to wait for all Task reviews to finish before launching the Coverage Verifier. Collect all results, fix all issues together, then start the next round.

**All per-Task subagents AND the Coverage Verifier must report OKAY before proceeding.** Any single failure means the whole round fails; loop again.

### Git Commit Discipline

- **Before the first review round:** commit the first version of the plan file.
- **After each round's fixes:** commit again with a message that identifies the round, e.g. `docs(plan): fix review round 2 - add missing migration task`.
- If the plan file is gitignored, skip the commit. **Never** use `git add -f` to force-add an ignored file.

## User Review Gate

After all per-Task subagents and the Coverage Verifier report OKAY, present the plan to the user for review.

If the user requests any changes:

1. Make the requested changes.
2. Re-run the per-Task review loop for every **affected Task** (can be dispatched in parallel).
3. Re-run the Coverage Verifier over the whole plan vs. the whole spec (edits can introduce new coverage gaps).
4. Loop each until OKAY, following the same zero-tolerance fix rules above.
5. Commit the fixed plan.
6. Report the result back to the user and **wait for their next reply**.

Only leave this gate once the user **explicitly approves** (e.g. "OK", "looks good", "start implementation"). Do not self-approve or assume approval from silence.

## Execution Handoff

After the user explicitly approves the plan:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Ready to start implementation? (using Subagent-Driven Development)"**

On confirmation, invoke the **REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`**. No alternative execution method is offered.
