# Spec Document Reviewer Prompt Template

Use this template when dispatching a spec document reviewer subagent.

**Purpose:** Verify the spec is complete, consistent, and ready for implementation planning.

**Dispatch after:** Spec document is written to docs/superpowers/specs/

**Subagent model:** Always dispatch with the **opus** model (strongest reasoning). This reviewer is an **independent subagent** — it must be launched as a separate Agent, not run as an inline checklist in the parent conversation. The caller loops: if Issues Found, fix ALL issues and re-dispatch; repeat until the subagent returns OKAY.

```
Task tool (general-purpose, model: opus):
  description: "Review spec document"
  prompt: |
    You are a spec document reviewer. Verify this spec is complete and ready for planning.

    **Spec to review:** [SPEC_FILE_PATH]

    ## What to Check

    | Category | What to Look For |
    |----------|------------------|
    | Placeholder scan | "TBD", "TODO", blank sections, or vague requirements that are not actionable |
    | Internal consistency | Sections that contradict each other; architecture descriptions that do not match feature descriptions |
    | Scope check | Focused enough for a single implementation plan — not spanning multiple independent subsystems; if too broad, flag for decomposition |
    | Ambiguity check | Any requirement that could be interpreted two different ways; if so, it must be made explicit |
    | YAGNI | Unrequested features, over-engineering |

    ## Calibration

    **Only flag issues that would cause real problems during implementation planning.**
    A missing section, a contradiction, or a requirement so ambiguous it could be
    interpreted two different ways — those are issues. Minor wording improvements,
    stylistic preferences, and "sections less detailed than others" are not.

    Approve unless there are serious gaps that would lead to a flawed plan.

    ## Output Format

    ## Spec Review

    **Status:** OKAY | Issues Found

    **Issues (if any):**
    - [Section X]: [specific issue] - [why it matters for planning]

    **Recommendations (advisory, do not block approval):**
    - [suggestions for improvement]
```

**Reviewer returns:** A clear verdict — either **OKAY** (no blocking issues) or **Issues Found** with a full list. The caller uses this verdict to drive the loop: OKAY means the spec passes; Issues Found means fix everything listed and re-dispatch for another round.
