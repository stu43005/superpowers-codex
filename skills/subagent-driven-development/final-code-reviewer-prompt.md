# Final Code Reviewer — `dispatch.sh adversarial`

Run once, after every task has passed both its spec compliance and code quality reviews.

**Purpose:** Challenge the entire implementation as a coherent whole — cross-task
integration seams, drift from the plan's overall intent, and ship/no-ship judgment. The
focus text lives in `final-code-reviewer-focus.md`.

Dispatch via the codex companion `adversarial-review` (the focus text is passed as the
trailing positional; `--wait` is a boolean flag). **Fill `<IMPL_BASE>` with the actual
`git rev-parse HEAD` captured before the very first implementer started this plan —
substitute the value into the command; do not run the line verbatim:**

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" adversarial \
  --base <IMPL_BASE> \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/final-code-reviewer-focus.md"
```

`<IMPL_BASE>` must be a direct ancestor of HEAD; `--base` makes the companion diff
`git diff $(git merge-base HEAD <IMPL_BASE>)..HEAD`, covering the entire implementation.

## Verdict parsing

- `Verdict: approve` → passes the final gate; proceed to `superpowers:finishing-a-development-branch`.
- `Verdict: needs-attention` → collect every finding (file, line range, recommendation),
  dispatch the implementer to fix all, then re-run from the start with the same
  `<IMPL_BASE>`. Repeat until `Verdict: approve`.

**Zero tolerance; do not ask the user** — the loop runs automatically until the gate clears.
