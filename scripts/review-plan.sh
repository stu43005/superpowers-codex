#!/usr/bin/env bash
# Writing-plans review wrapper: dispatch per-Task reviewers (+ optional coverage) in
# one batch.
# Usage: review-plan.sh --plan <plan.md> --spec <design.md> \
#          --task "Task 1" [--task "Task 3" ...] [--coverage] [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# BATCH_DISPATCH_SH is a deliberate TEST SEAM: review-batch-lib.test.sh injects a stub dispatch.sh
# through it for hermetic testing. With no override it resolves to the real dispatch.sh; keep it.
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-plan: %s requires a value\n' "$1" >&2; exit 1; }; }

PLAN=""; SPEC=""; COVERAGE=0
TASKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)         need_val "$1" "$#"; PLAN="$2"; shift 2 ;;
    --spec)         need_val "$1" "$#"; SPEC="$2"; shift 2 ;;
    --task)         need_val "$1" "$#"; TASKS+=("$2"); shift 2 ;;
    --coverage)     COVERAGE=1; shift ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-plan: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PLAN" ] || { printf 'review-plan: --plan is required\n' >&2; exit 1; }
[ -n "$SPEC" ] || { printf 'review-plan: --spec is required\n' >&2; exit 1; }
if [ "${#TASKS[@]}" -eq 0 ] && [ "$COVERAGE" -eq 0 ]; then
  printf 'review-plan: at least one --task or --coverage is required\n' >&2
  exit 1
fi

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
if [ "${#TASKS[@]}" -gt 0 ]; then
  for tid in "${TASKS[@]}"; do
    batch_add "per-task $tid" task \
      --prompt "$PLUGIN_ROOT/skills/writing-plans/plan-document-reviewer-prompt.md" \
      --set "PLAN_FILE_PATH=$PLAN" \
      --set "SPEC_FILE_PATH=$SPEC" \
      --set "TASK_ID=$tid"
  done
fi
if [ "$COVERAGE" -eq 1 ]; then
  batch_add "coverage-verifier" task \
    --prompt "$PLUGIN_ROOT/skills/writing-plans/coverage-verifier-prompt.md" \
    --set "PLAN_FILE_PATH=$PLAN" \
    --set "SPEC_FILE_PATH=$SPEC"
fi
batch_run
