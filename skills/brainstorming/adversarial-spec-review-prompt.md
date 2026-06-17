# Adversarial Spec Review — `dispatch.sh adversarial`

The design-soundness half of the brainstorming dual spec review. The focus text lives in
`adversarial-spec-review-focus.md`.

Dispatch via the codex companion `adversarial-review` (the focus text is passed as the
trailing positional; `--wait` is a boolean flag). **Fill `<SPEC_BASE>` with the SHA captured
before writing/committing the spec file — HEAD at that moment (the parent of the spec commit,
`git rev-parse HEAD`); substitute the value into the command, do not run the line verbatim:**

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" adversarial \
  --base <SPEC_BASE> \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/brainstorming/adversarial-spec-review-focus.md"
```

Do NOT re-capture `<SPEC_BASE>` after the spec commit; it must stay the direct ancestor so
the review diffs exactly the new spec content.

## Verdict parsing

- `Verdict: approve` → spec passes this reviewer.
- `Verdict: needs-attention` → fix every finding, then re-run BOTH spec reviewers — the
  structural-completeness reviewer and this adversarial reviewer re-run together whenever
  any spec edit is made.
