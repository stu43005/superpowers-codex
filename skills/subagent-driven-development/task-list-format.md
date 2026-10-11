# Task List Format

In Phase 0 the controller derives a task list from the approved spec. The list lives only in the
controller's session state: it is listed in full in the controller's reply, never written to a
file, and never committed. This file defines how to decompose a spec into tasks and what each task
definition looks like.

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project
specs during brainstorming. If it wasn't, tell your human partner and suggest splitting it into one
spec per subsystem before implementing. Each spec should produce working, testable software on its
own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is
responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear
  responsibility.
- Implementers reason best about code they can hold in context at once, and their edits are more
  reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't
  unilaterally restructure — but if a file being modified has grown unwieldy, including a split in
  a task is reasonable.

This structure informs the task decomposition. Each task should produce a self-contained change
that makes sense on its own.

## Task Definition

Every task uses exactly these fields, in this order:

```
Task 3: Retry policy
Spec: §4.2, §4.3
Files: src/retry.ts (new), src/client.ts
Interface: export function withRetry(fn, opts)
Acceptance:
- retries up to opts.max on 5xx
- no retry on 4xx
- backoff doubles each attempt
Depends on: Task 1 (HttpError type)
```

Field rules:

- **`Task N: <name>`** — `N` is a positive integer, unique within the list. `<name>` is a short
  single-line name. `N` and `<name>` form the task's identity: they are reused verbatim in the task
  summary line and in the commit trailer `Task: <N> <name>`, and never change once the task has a
  commit.
- **`Spec:`** — the spec sections this task touches; at least one. Cite the spec's own section
  numbers (for example `§4.2`); if the spec has no numbered sections, cite the exact heading text.
  The same section may be split across several tasks; what this task is responsible for within a
  section is defined by its `Acceptance:`.
- **`Files:`** — the files the task expects to create or modify. Mark new files with `(new)`.
- **`Interface:`** — what this task exposes to other tasks (functions, types, CLI arguments, file
  formats, and so on); write `none` if nothing. Signatures only, never implementations.
- **`Acceptance:`** — verifiable acceptance criteria, one per line. Executable behavior must be
  checkable by a test; declarative changes (instruction text, configuration values, documentation)
  are checkable by their location.
- **`Depends on:`** — the tasks this one depends on and the interface it uses from each; write
  `none` if nothing.

## Ordering and Dependencies

- `Depends on:` may only reference **lower-numbered** tasks. Order the list so that every task's
  dependencies are complete when it starts.
- If the dependencies cannot be ordered that way (a dependency cycle), merge the tasks in the cycle
  into one task.
- Tasks appended later (final-gate repairs, requirements no existing task covers) are numbered after
  the highest existing number and follow the same rules.

## No Code in Tasks

A task definition never contains implementation code, test code, or step-by-step instructions. The
implementer designs the code and tests itself, using TDD, from `Interface:` and `Acceptance:`.

## Task Summary Line

For each task the controller produces one summary line:

```
Task N: <name> (spec §X, §Y)
```

The sections are exactly the task's `Spec:` sections, for example
`Task 3: Retry policy (spec §4.2, §4.3)`. Whenever `Spec:` changes, regenerate the line.

- It is the **only** scope information reviewers receive, passed as `--task-summary` to
  `review-impl.sh`. Reviewers never see the task list or `Acceptance:`.
- It **must be a single line**. The dispatcher rejects values containing a newline and the wrapper
  fails; rewrite the line without newlines and re-run.
