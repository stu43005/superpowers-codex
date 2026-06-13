# Coverage Verifier Prompt Template

Use this template when dispatching a coverage verifier subagent.

**Purpose:** Verify that the **whole plan** covers the **whole spec** — a global coverage check across all Tasks, not a per-Task review. This catches gaps that per-Task reviewers miss because they only see one Task at a time.

**Dispatch after:** All per-Task review subagents have reported OKAY for the current round. The coverage verifier runs in parallel with per-Task reviews whenever possible (you do not need to wait for all Task reviews to finish before dispatching this). The caller loops — dispatching a fresh subagent — until this subagent returns **OKAY**.

```
Task tool (general-purpose):
  description: "Coverage verification: plan vs. spec"
  prompt: |
    You are an independent coverage verifier. You are dispatched as a separate agent
    (not an inline checklist) and you must use rigorous judgment. Your job is to compare
    the ENTIRE plan against the ENTIRE spec and identify anything in the spec that the
    plan fails to cover, silently changes, or weakens.

    **Plan file:** [PLAN_FILE_PATH]
    **Spec file:** [SPEC_FILE_PATH]

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

    **Verdict:** OKAY | Issues Found

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
```

**Reviewer returns:** Verdict (OKAY or Issues Found), Coverage Gaps, Design Decision Gaps, Implicit Requirement Gaps, Cross-Task Integration Gaps, Out-of-Scope Content
