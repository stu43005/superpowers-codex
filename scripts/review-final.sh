#!/usr/bin/env bash
# Subagent-driven-development final adversarial merge-gate wrapper: dispatch the final
# adversarial reviewer in one batch.
# Usage: review-final.sh --base <IMPL_BASE> [--max-parallel N]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BATCH_DISPATCH_SH="${BATCH_DISPATCH_SH:-$SCRIPT_DIR/dispatch.sh}"
PLUGIN_ROOT="${PLUGIN_ROOT:-$SCRIPT_DIR/..}"
export BATCH_DISPATCH_SH

# need_val: fail with a clear wrapper error when an option is missing its value, instead
# of crashing on an unbound `$2` under `set -u`.
need_val() { [ "$2" -ge 2 ] || { printf 'review-final: %s requires a value\n' "$1" >&2; exit 1; }; }

BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)         need_val "$1" "$#"; BASE="$2"; shift 2 ;;
    --max-parallel) need_val "$1" "$#"; MAX_PARALLEL="$2"; shift 2 ;;
    *) printf 'review-final: unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$BASE" ] || { printf 'review-final: --base is required\n' >&2; exit 1; }

# shellcheck source=./review-batch-lib.sh
. "$SCRIPT_DIR/review-batch-lib.sh"
batch_init
batch_add "final-adversarial" adversarial \
  --base "$BASE" \
  --focus "$PLUGIN_ROOT/skills/subagent-driven-development/final-code-reviewer-focus.md"
batch_run
