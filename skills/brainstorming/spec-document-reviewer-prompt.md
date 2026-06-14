# Spec Document Reviewer Prompt Template (Reviewer 1 — Structural Completeness)

Use this template when dispatching the structural completeness reviewer for a spec document.

**Purpose:** Verify the spec is complete, consistent, and ready for implementation planning.

**Dispatch after:** Spec document is written to `docs/superpowers/specs/` and committed.

**Mechanism:** codex companion `task` (read-only). No `--write` flag — Codex runs in read-only mode. The caller loops: if `Issues Found`, fix ALL issues and re-dispatch; repeat until Codex returns `Status: OKAY`.

## Invocation

> **Run this block as-is — do not pre-verify the companion.** The path-resolution step
> below already locates the companion (`ls … | sort -V | tail -1`, with a marketplace
> fallback) and exits with a clear error if it is absent. Do NOT separately `ls`/`find`
> for the companion, run `node "$CODEX_COMPANION" --help`, or grep the companion source
> before dispatching. The `task --prompt-file <path>` flag IS supported — the companion
> reads `options["prompt-file"]` and lists `prompt-file` among its value options — even
> though `--help` does not document it. This is verified, not a guess, so no
> re-verification is needed.

```bash
# Step 1: Resolve companion path
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi

# Step 2: Write the review prompt to a temp file and dispatch
PROMPT_FILE="$(mktemp)"
cat > "$PROMPT_FILE" <<'PROMPT'
You are a spec document reviewer. Your job is to verify that the spec document at the path given below is structurally complete and ready for implementation planning. Read the file, then apply each check in the table below.

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

Only flag issues that would cause real problems during implementation planning.
A missing section, a contradiction, or a requirement so ambiguous it could be
interpreted two different ways — those are issues. Minor wording improvements,
stylistic preferences, and "sections less detailed than others" are not.

Approve unless there are serious gaps that would lead to a flawed plan.

## Output Format

Your response MUST end with exactly one of these two final lines (the last line of your entire response):

    Status: OKAY

or

    Status: Issues Found

If issues are found, list each one before the final Status line using this format:

**Issues:**
- [Section/area]: [specific issue] — [why it matters for planning]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement that should NOT appear in Issues]
PROMPT
node "$CODEX_COMPANION" task --prompt-file "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

**Verdict parsing:** The caller reads the final `Status:` line of Codex output.
- `Status: OKAY` → spec passes this reviewer; proceed.
- `Status: Issues Found` → fix every listed issue, re-run this invocation for the next round.
