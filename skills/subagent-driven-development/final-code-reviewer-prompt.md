# Final Code Reviewer — Codex Adversarial Review Dispatch

Run once, after every task has passed both its spec compliance review and code quality review. Dispatches reviewer 7 via codex companion `adversarial-review --base <IMPL_BASE>`.

**Purpose:** Challenge the entire implementation as a coherent whole — cross-task integration seams, drift from the plan's overall intent, and ship/no-ship merge judgment. Each individual task has already been reviewed; this reviewer looks for problems that only appear when the tasks are seen together.

**Dispatch once, at the end.** Do not run per-task.

---

## Step 1: Retrieve IMPL_BASE

`IMPL_BASE` must have been captured (as `git rev-parse HEAD`) at the moment before the very first implementer subagent started work on this plan — i.e., the commit that existed before any implementation began. Retrieve it from your task-tracking state. This SHA must be a direct ancestor of the current HEAD.

## Step 2: Locate codex companion

> **Run this block as-is — do not pre-verify the companion.** The block below already
> locates the companion (`ls … | sort -V | tail -1`, with a marketplace fallback) and
> exits with a clear error if it is absent. Do NOT separately `ls`/`find` for the
> companion, run `node "$CODEX_COMPANION" --help`, or grep the companion source to
> confirm the subcommand or flags before dispatching — the `adversarial-review --base
> <ref> --wait <focus>` invocation in Step 3 is canonical and verified.

```bash
CODEX_COMPANION="$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)"
[ -z "$CODEX_COMPANION" ] && CODEX_COMPANION="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
if [ ! -f "$CODEX_COMPANION" ]; then
  echo "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review." >&2
  exit 1
fi
```

## Step 3: Run adversarial review

Substitute `[IMPL_BASE]` with the actual SHA captured in Step 1.

```bash
node "$CODEX_COMPANION" adversarial-review --base [IMPL_BASE] --wait "Focus: challenge cross-task integration seams — types, interfaces, naming conventions, and shared state that must be consistent across task boundaries; drift from the plan's overall intent (requirements that fell through the cracks between tasks, scaffolding or TODOs left behind, dead code from the task-by-task process); and the ship/no-ship merge judgment for the implementation as a whole. Adversarially probe: auth/permissions/isolation correctness across the full change set, data-loss or corruption risks introduced by the combined changes, rollback and partial-failure behavior end-to-end, race conditions and ordering assumptions that span multiple tasks, missing observability (logging/metrics/tracing) for the integrated feature."
```

The `--base` flag instructs the companion to diff `git diff $(git merge-base HEAD [IMPL_BASE])..HEAD`. Because `IMPL_BASE` is a direct ancestor of HEAD, the merge-base equals `IMPL_BASE`, so the reviewed diff covers the entire implementation.

## Step 4: Interpret the verdict

The `adversarial-review` command emits a structured `Verdict:` line in its output:

- `Verdict: approve` → the implementation passes the final gate. Proceed to `superpowers:finishing-a-development-branch`.
- `Verdict: needs-attention` → the adversarial reviewer found material problems. Collect every finding (each includes `file`, `line_start`–`line_end`, and `recommendation`). Dispatch the implementer subagent to address all findings. After fixes are committed, re-run this reviewer from Step 1 with the same `IMPL_BASE`. Repeat until `Verdict: approve`.

**Zero tolerance:** Do not proceed to `finishing-a-development-branch` while `Verdict: needs-attention` remains.

**Do not ask the user** whether to re-run or proceed. This loop runs automatically until the final gate clears.
