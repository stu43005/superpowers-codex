# Adversarial Spec Review Prompt Template (Reviewer 2 — Design Soundness)

Use this template when dispatching the adversarial design reviewer for a spec document.

**Purpose:** Challenge the design-level soundness and completeness of a not-yet-implemented spec. This reviewer is adversarial — it attacks assumptions, failure paths, and edge cases at the design level. It does NOT do line-by-line structural checks (that is Reviewer 1's job).

**Dispatch after:** Spec document is written and committed. Run in parallel with Reviewer 1 each round.

**Mechanism:** codex companion `adversarial-review --base <SPEC_BASE>`. The diff reviewed is the new spec commit (everything since `SPEC_BASE`). The caller loops: if `needs-attention`, fix ALL findings and re-dispatch both reviewers; repeat until this reviewer returns `approve` AND Reviewer 1 returns `OKAY`.

## Capturing SPEC_BASE

`SPEC_BASE` must be captured **before** writing or committing the spec file — it is the HEAD at that moment (the parent commit of the spec commit). Capture it with:

```bash
SPEC_BASE="$(git rev-parse HEAD)"
```

Run this line immediately before writing the spec file. Store `SPEC_BASE` for use in all subsequent rounds of this reviewer. Do NOT re-capture it after the spec commit — it must remain the direct ancestor of the spec commit so that `adversarial-review --base <SPEC_BASE>` diffs exactly the new spec content.

If the spec file is gitignored and cannot be committed, skip this reviewer for this round and note the skip in your output (consistent with the git commit discipline: never use `git add -f`).

## Invocation

```bash
# Step 1: Resolve companion path
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi

# Step 2: Dispatch adversarial review against the spec diff
node "$CODEX_COMPANION" adversarial-review --base "$SPEC_BASE" --wait "Focus on design-level soundness and completeness of this not-yet-implemented spec. Challenge: (1) failure paths, partial failure, and rollback — what happens when any step fails mid-way; (2) concurrency and ordering assumptions — are there implicit sequencing requirements that are never stated; (3) boundary and empty states — zero items, maximum limits, empty input, first-run with no prior state; (4) compatibility and migration risk — does this design interact with existing data, APIs, or systems in ways that could break them; (5) unstated but critical assumptions — what must be true in the environment, dependencies, or caller behaviour for this design to work. Report only material design-level findings. Do not perform line-by-line wording review."
```

**Verdict parsing:** The caller reads the `Verdict:` line from Codex output.
- `Verdict: approve` → spec passes this reviewer; proceed.
- `Verdict: needs-attention` → fix every listed finding, then re-run BOTH Reviewer 1 and Reviewer 2 for the next round (both reviewers re-run together whenever any spec edit is made).
