#!/usr/bin/env bash
# Subagent-driven-development per-task review wrapper: dispatch the spec-compliance,
# code-quality, task-coverage and task-seam reviewers in parallel for one Task.
# Usage: review-impl.sh --spec <design.md> --task-summary "Task N: <name> (spec §X)" \
#          --task-base <TASK_BASE> [--max-parallel N]
# --task-summary must be a single line: dispatch.sh rejects a --set value containing a newline.
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

SPEC=""; TASK_SUMMARY=""; TASK_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)         need_val "$1" "$#"; SPEC="$2"; shift 2 ;;
    --task-summary) need_val "$1" "$#"; TASK_SUMMARY="$2"; shift 2 ;;
    --task-base)    need_val "$1" "$#"; TASK_BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-impl: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$SPEC" ]         || { printf 'review-impl: --spec is required\n' >&2; exit 1; }
[ -n "$TASK_SUMMARY" ] || { printf 'review-impl: --task-summary is required\n' >&2; exit 1; }
[ -n "$TASK_BASE" ]    || { printf 'review-impl: --task-base is required\n' >&2; exit 1; }

SDD_DIR="$PLUGIN_ROOT/skills/subagent-driven-development"

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "spec-compliance" task \
  --prompt "$SDD_DIR/spec-reviewer-prompt.md" \
  --set "SPEC_FILE_PATH=$SPEC" \
  --set "TASK_SUMMARY=$TASK_SUMMARY" \
  --set "TASK_BASE=$TASK_BASE"
batch_add "code-quality" review --base "$TASK_BASE"
batch_add "task-coverage" task \
  --prompt "$SDD_DIR/task-coverage-prompt.md" \
  --set "SPEC_FILE_PATH=$SPEC" \
  --set "TASK_SUMMARY=$TASK_SUMMARY" \
  --set "TASK_BASE=$TASK_BASE"
# task-seam never reads the spec: it checks the diff against the existing code only.
batch_add "task-seam" task \
  --prompt "$SDD_DIR/task-seam-prompt.md" \
  --set "TASK_BASE=$TASK_BASE"
batch_run
