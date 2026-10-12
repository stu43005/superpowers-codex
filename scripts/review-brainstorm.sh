#!/usr/bin/env bash
# Brainstorming spec-review wrapper: dispatch the two spec reviewers in one batch.
# Usage: review-brainstorm.sh --spec <design.md> --base <SPEC_BASE> [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# BATCH_DISPATCH_SH, BATCH_DISPATCH_CLAUDE_SH and BATCH_QUOTA_PROBE are deliberate TEST SEAMS:
# review-batch-lib.test.sh injects stub dispatchers and a fake quota probe through them for
# hermetic testing. With no override they resolve to the shipped scripts; keep them.
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
BATCH_DISPATCH_CLAUDE_SH="${BATCH_DISPATCH_CLAUDE_SH:-$SCRIPT_DIR/dispatch-claude.sh}"
BATCH_QUOTA_PROBE="${BATCH_QUOTA_PROBE:-$SCRIPT_DIR/codex-quota.mjs}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH BATCH_DISPATCH_CLAUDE_SH BATCH_QUOTA_PROBE

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-brainstorm: %s requires a value\n' "$1" >&2; exit 1; }; }

SPEC=""; BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)         need_val "$1" "$#"; SPEC="$2"; shift 2 ;;
    --base)         need_val "$1" "$#"; BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-brainstorm: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$SPEC" ] || { printf 'review-brainstorm: --spec is required\n' >&2; exit 1; }
[ -n "$BASE" ] || { printf 'review-brainstorm: --base is required\n' >&2; exit 1; }

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "structural-completeness" task \
  --prompt "$PLUGIN_ROOT/skills/brainstorming/spec-document-reviewer-prompt.md" \
  --set "SPEC_FILE_PATH=$SPEC"
batch_claude_model sonnet
batch_add "design-soundness" adversarial \
  --base "$BASE" \
  --focus "$PLUGIN_ROOT/skills/brainstorming/adversarial-spec-review-focus.md"
batch_claude_model opus
batch_run
