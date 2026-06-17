# Final Code Reviewer — `dispatch.sh adversarial`

Reviewer 7. Run once, after every task has passed both its spec compliance and code
quality reviews. Dispatched via
`dispatch.sh adversarial --base <IMPL_BASE> --focus <…>/final-code-reviewer-focus.md`
(codex companion `adversarial-review`; focus text is the trailing positional, `--wait` is
boolean). The focus text lives in `final-code-reviewer-focus.md`.

**Purpose:** Challenge the entire implementation as a coherent whole — cross-task
integration seams, drift from the plan's overall intent, and ship/no-ship judgment.

`IMPL_BASE` is the `git rev-parse HEAD` captured before the very first implementer started
this plan; it must be a direct ancestor of HEAD. `--base` makes the companion diff
`git diff $(git merge-base HEAD <IMPL_BASE>)..HEAD`, covering the entire implementation.

## Verdict parsing

- `Verdict: approve` → passes the final gate; proceed to `superpowers:finishing-a-development-branch`.
- `Verdict: needs-attention` → collect every finding (file, line range, recommendation),
  dispatch the implementer to fix all, then re-run from the start with the same
  `IMPL_BASE`. Repeat until `Verdict: approve`.

**Zero tolerance; do not ask the user** — the loop runs automatically until the gate clears.

(The exact dispatch invocation lives in the subagent-driven-development SKILL.md.)
