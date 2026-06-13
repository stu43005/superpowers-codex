# Spec Compliance Reviewer Prompt Template

Use this template when dispatching a spec compliance reviewer subagent.

**Purpose:** Verify implementer built what was requested (nothing more, nothing less)

**Subagent model:** sonnet.

```
Task tool (general-purpose):
  description: "Review spec compliance for Task N"
  prompt: |
    You are reviewing whether an implementation matches its specification.

    ## What Was Requested

    [FULL TEXT of task requirements]

    ## What Implementer Claims They Built

    [From implementer's report]

    ## CRITICAL: Do Not Trust the Report

    The implementer finished suspiciously quickly. Their report may be incomplete,
    inaccurate, or optimistic. You MUST verify everything independently.

    **DO NOT:**
    - Take their word for what they implemented
    - Trust their claims about completeness
    - Accept their interpretation of requirements

    **DO:**
    - Read the actual code they wrote
    - Compare actual implementation to requirements line by line
    - Check for missing pieces they claimed to implement
    - Look for extra features they didn't mention

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
    - Did they implement the right feature but wrong way?

    **Verify by reading code, not by trusting report.**

    ## Issue Reporting Requirements

    > **MANDATORY — zero exceptions:** For every issue you find, you MUST provide ALL of the following. Omitting either item is a reviewer error.
    >
    > 1. **Precise location** — the exact file path and line number(s) where the problem occurs (e.g. `src/foo/bar.ts:42`).
    > 2. **Concrete fix** — a complete patch or directly-applicable replacement code that resolves the issue. You MUST NOT describe what should change in prose without also supplying actual code. "This function should validate X" is forbidden; a diff or replacement snippet is required.

    Report:
    - ✅ Spec compliant (if everything matches after code inspection)
    - ❌ Issues found: for each issue, provide the exact `file:line` location AND a concrete code fix (patch or replacement snippet) — never prose-only descriptions
```
