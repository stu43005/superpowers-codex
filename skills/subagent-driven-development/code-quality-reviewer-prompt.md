# Code Quality Reviewer — `dispatch.sh review`

Run after the spec compliance reviewer returns `Status: OKAY` for a task. It calls the codex
companion's native `review` command. There is **no prompt sidecar** — the native reviewer
owns the quality judgment, and `review` does not read a `--prompt-file`.

**Purpose:** Let Codex's native reviewer assess code quality and surface bugs or
correctness problems in the task's diff.

Dispatch — **fill `<TASK_BASE>`** with the `git rev-parse HEAD` captured immediately before
this task's implementer started; substitute the value into the command, do not run it
verbatim:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" review --base <TASK_BASE>
```

`<TASK_BASE>` must be a direct ancestor of HEAD; `--base` makes the companion diff
`git diff $(git merge-base HEAD <TASK_BASE>)..HEAD`, i.e. exactly this task's commits.

## Interpreting the output (prose, not a Verdict line)

The native `review` command returns **free-form prose**, not a structured `Verdict:` line
(that field exists only for `adversarial-review`). The parent agent interprets it:

- **Any blocking-severity defect** (a bug, a clear correctness issue, a quality problem
  that would block a confident merge) → treat as **Issues Found**: extract file:line +
  recommendation, dispatch the implementer to fix all blocking issues, then re-run this
  reviewer. Repeat until no blocking findings remain.
- **No significant issues** (or only minor style notes) → treat as **OKAY**: mark the
  quality gate passed and proceed.

**Severity calibration:** "blocking" = what a senior engineer would require fixed before
merge — bugs, data-loss risks, broken error handling, security issues, missing critical
test coverage. Style preferences do not trigger a re-review loop.

**Do not ask the user** whether to re-run or proceed — the loop runs automatically until
the quality gate clears.
