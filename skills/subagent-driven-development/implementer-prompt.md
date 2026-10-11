# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent.

**Subagent model:** choose per the Model Selection section of `SKILL.md`, by the task's complexity.
The task carries no code — the implementer designs the code and tests itself — so do not default to
the cheapest model for tasks that need design judgment.

```
Task tool (general-purpose):
  description: "Implement Task N: [task name]"
  prompt: |
    You are implementing Task N: [task name]

    ## Task Definition

    [FULL TEXT of the task definition (provided by the controller) — paste it here,
    including Spec:, Files:, Interface:, Acceptance:, and Depends on:]

    ## Spec

    The approved spec is at: [SPEC_FILE_PATH]
    Read the sections listed in the task's `Spec:` field. The spec is the source of truth for
    requirements; the task's `Acceptance:` defines which of them this task is responsible for.

    ## Context

    [Scene-setting: where this fits, what earlier tasks already built, the interfaces from
    `Depends on:` and where they live, architectural context]

    ## Before You Begin

    If you have questions about:
    - The requirements or acceptance criteria
    - The approach or implementation strategy
    - Dependencies or assumptions
    - Anything unclear in the task definition

    **Ask them now.** Raise any concerns before starting work.

    ## Your Job

    The task definition contains no code. You design the implementation and tests yourself from
    `Interface:` and `Acceptance:`, consistent with the spec sections in `Spec:`.

    Once you're clear on requirements:
    1. Follow TDD for every executable acceptance criterion, in this order:
       a. Write a test that describes the target behavior
       b. Run it and see it fail — the failure must come from the asserted behavior, not from a
          missing module or a type error
       c. Write the implementation
       d. Run it and see it pass
       Declarative changes (instruction text, configuration values, documentation) need no
       executable test; make the change at the right location.
    2. Implement exactly what the task specifies — every `Acceptance:` item, nothing more
    3. Self-review (see below) and fix anything it finds
    4. Verify the implementation works (run the relevant tests and checks, after any self-review fixes)
    5. Commit your work (every commit with the trailer below)
    6. Report back

    Work from: [directory]

    **While you work:** If you encounter something unexpected or unclear, **ask questions**.
    It's always OK to pause and clarify. Don't guess or make assumptions.

    ## Commits

    End every commit message — including fix commits after review — with this trailer, in the
    final paragraph alongside any other trailers such as `Co-Authored-By:`:

        [TASK_TRAILER]

    (for example `Task: 3 Retry policy`). Use exactly the trailer given here; never invent or
    alter it.

    ## The Spec Is Read-Only

    Never modify [SPEC_FILE_PATH] or any other file under `docs/superpowers/specs/`. If you believe
    the spec is wrong, incomplete, or contradicts the codebase, do not work around it silently:
    report DONE_WITH_CONCERNS (if you could still complete the task) or BLOCKED, and describe the
    problem. The controller decides whether the spec changes.

    Code and comments must not reference the spec, its section numbers, or task numbers
    (no "per spec §4", no "see Task 2").

    ## Third-Party APIs

    If the implementation depends on third-party library or tool behavior that neither the spec
    nor the Context section above documents with a confirmed research conclusion, do not guess
    it. Report NEEDS_CONTEXT and list each API and behavior that needs confirmation (package,
    version, the exact question). A confirmed research conclusion the controller supplies in the
    Context section resolves the need just as one in the spec does.

    ## Code Organization

    You reason best about code you can hold in context at once, and your edits are more
    reliable when files are focused. Keep this in mind:
    - Follow the file structure defined in the task's `Files:` field
    - Each file should have one clear responsibility with a well-defined interface
    - If a file you're creating is growing beyond the task's intent, stop and report
      it as DONE_WITH_CONCERNS — don't split files on your own without controller guidance
    - If an existing file you're modifying is already large or tangled, work carefully
      and note it as a concern in your report
    - In existing codebases, follow established patterns. Improve code you're touching
      the way a good developer would, but don't restructure things outside your task.

    ## When You're in Over Your Head

    It is always OK to stop and say "this is too hard for me." Bad work is worse than
    no work. You will not be penalized for escalating.

    **STOP and escalate when:**
    - The task requires architectural decisions with multiple valid approaches the spec doesn't settle
    - You need to understand code beyond what was provided and can't find clarity
    - You feel uncertain about whether your approach is correct
    - The task involves restructuring existing code in ways the task definition didn't anticipate
    - You've been reading file after file trying to understand the system without progress

    **How to escalate:** Report back with status BLOCKED or NEEDS_CONTEXT. Describe
    specifically what you're stuck on, what you've tried, and what kind of help you need.
    The controller can provide more context, re-dispatch with a more capable model,
    or break the task into smaller pieces.

    ## Before Reporting Back: Self-Review

    Review your work with fresh eyes. Ask yourself:

    **Completeness:**
    - Did I implement every `Acceptance:` item?
    - Is the result consistent with the spec sections in `Spec:`?
    - Are there edge cases I didn't handle?

    **Quality:**
    - Is this my best work?
    - Are names clear and accurate (match what things do, not how they work)?
    - Is the code clean and maintainable?

    **Discipline:**
    - Did I avoid overbuilding (YAGNI)?
    - Did I only build what was requested?
    - Did I follow existing patterns in the codebase?
    - Does every commit end with the exact `Task:` trailer?
    - Did I leave the spec file untouched?

    **Testing:**
    - Do tests actually verify behavior (not just mock behavior)?
    - Did I write each test and see it fail before implementing?
    - Are tests comprehensive?

    If you find issues during self-review, fix them now, re-run the relevant tests, and commit the
    fixes with the trailer before reporting. Never report with uncommitted changes.

    ## Report Format

    When done, report:
    - **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - What you implemented (or what you attempted, if blocked)
    - What you tested and test results, including the failing run you saw before implementing
    - Files changed
    - Self-review findings (if any)
    - Any issues or concerns (including any problem you found in the spec)

    Use DONE_WITH_CONCERNS if you completed the work but have doubts about correctness.
    Use BLOCKED if you cannot complete the task. Use NEEDS_CONTEXT if you need
    information that wasn't provided. Never silently produce work you're unsure about.
```
