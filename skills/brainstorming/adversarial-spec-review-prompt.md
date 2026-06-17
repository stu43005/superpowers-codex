# Adversarial Spec Review — `dispatch.sh adversarial`

Reviewer 2 of the brainstorming dual-review loop. Dispatched via
`dispatch.sh adversarial --base <SPEC_BASE> --focus <…>/adversarial-spec-review-focus.md`,
which calls the codex companion `adversarial-review` (focus text passed as the trailing
positional; `--wait` is a boolean flag). The focus text lives in
`adversarial-spec-review-focus.md`.

## Capturing SPEC_BASE

`SPEC_BASE` must be captured **before** writing/committing the spec file — it is HEAD at
that moment (the parent of the spec commit): `SPEC_BASE="$(git rev-parse HEAD)"`. Do NOT
re-capture after the spec commit; it must stay the direct ancestor so the review diffs
exactly the new spec content.

## Verdict parsing

- `Verdict: approve` → spec passes this reviewer.
- `Verdict: needs-attention` → fix every finding, then re-run BOTH Reviewer 1 and
  Reviewer 2 (they re-run together whenever any spec edit is made).

(The exact dispatch invocation lives in the brainstorming SKILL.md.)
