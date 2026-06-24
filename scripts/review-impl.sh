#!/usr/bin/env bash
# Subagent-driven-development per-task review wrapper: dispatch spec-compliance and
# code-quality reviewers in parallel for one Task.
# Usage: review-impl.sh --plan <plan.md> --task "Task N" --task-base <TASK_BASE> \
#          [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# BATCH_DISPATCH_SH is a deliberate TEST SEAM: review-batch-lib.test.sh injects a stub dispatch.sh
# through it for hermetic testing. With no override it resolves to the real dispatch.sh; keep it.
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-impl: %s requires a value\n' "$1" >&2; exit 1; }; }

PLAN=""; TASK=""; TASK_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         need_val "$1" "$#"; PLAN="$2"; shift 2 ;;
    --task)         need_val "$1" "$#"; TASK="$2"; shift 2 ;;
    --task-base)    need_val "$1" "$#"; TASK_BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-impl: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PLAN" ]      || { printf 'review-impl: --plan is required\n' >&2; exit 1; }
[ -n "$TASK" ]      || { printf 'review-impl: --task is required\n' >&2; exit 1; }
[ -n "$TASK_BASE" ] || { printf 'review-impl: --task-base is required\n' >&2; exit 1; }

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "spec-compliance" task \
  --prompt "$PLUGIN_ROOT/skills/subagent-driven-development/spec-reviewer-prompt.md" \
  --set "PLAN_FILE_PATH=$PLAN" \
  --set "TASK_ID=$TASK" \
  --set "TASK_BASE=$TASK_BASE"
batch_add "code-quality" review --base "$TASK_BASE"
batch_run
