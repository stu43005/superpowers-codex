#!/usr/bin/env bash
# Claude reviewer dispatch for the superpowers-codex plugin (runs `claude -p`).
# Subcommands: task | review | adversarial — same arguments as dispatch.sh, plus an
# optional `--model <alias>` forwarded verbatim to `claude -p --model <alias>`.
# Override the claude executable for tests with DISPATCH_CLAUDE_BIN.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_DIR="$SCRIPT_DIR/claude-prompts"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/dispatch-prompt-lib.sh"

# Overrides the plan-mode workflow instructions that --permission-mode plan injects,
# so the reviewer ends with the prompt's own Status:/Verdict: contract.
REVIEWER_SYSTEM_NOTE="You are a single-turn, read-only reviewer invoked non-interactively. Ignore any plan-mode workflow instructions (do not write plan files, do not call ExitPlanMode or AskUserQuestion, do not launch subagents). Perform the review requested in the user prompt and end your reply exactly as the prompt's output contract requires."

MODEL=""
# split_model_arg <args...>: pull `--model <alias>` out of a subcommand's arguments.
# Sets MODEL and REST (the remaining arguments, in order). Values of other
# value-taking options are copied untouched, even if they look like `--model`.
split_model_arg() {
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        [ $# -ge 2 ] && [ -n "$2" ] || die "--model requires a value"
        MODEL="$2"; shift 2 ;;
      --prompt|--report-file|--set|--base|--focus)
        [ $# -ge 2 ] || die "$1 requires a value"
        REST+=("$1" "$2"); shift 2 ;;
      *) REST+=("$1"); shift ;;
    esac
  done
}

# Sets REPLY_ARGS to the full `claude` argv (without the executable).
build_claude_args() {
  REPLY_ARGS=(-p --permission-mode plan --strict-mcp-config
    --tools "Read,Grep,Glob,Bash" --disallowedTools "mcp__*"
    --disable-slash-commands --no-session-persistence --output-format text
    --settings '{"disableAllHooks":true}' --max-turns 200
    --append-system-prompt "$REVIEWER_SYSTEM_NOTE")
  if [ -n "$MODEL" ]; then REPLY_ARGS+=(--model "$MODEL"); fi
}

# run_claude <prompt-file> <dry 0|1>: feed the rendered prompt to `claude -p` via stdin.
# Runs in the foreground; stdout streams untouched and claude's exit code is returned.
run_claude() {
  local work="$1" dry="$2" bin="${DISPATCH_CLAUDE_BIN:-claude}"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    err "dispatch-claude: ANTHROPIC_API_KEY is set; claude -p will bill the API key"
  fi
  build_claude_args
  if [ "$dry" -eq 1 ]; then
    printf -- '--- DRY RUN: command ---\n'
    printf '%q' "$bin"; printf ' %q' "${REPLY_ARGS[@]}"; printf ' < %q\n' "$work"
    printf -- '--- DRY RUN: prompt ---\n'
    cat "$work"
    return 0
  fi
  # Never fall back to codex: a missing claude is a hard failure.
  command -v "$bin" >/dev/null 2>&1 || die "claude CLI not found ($bin); install Claude Code or set DISPATCH_CLAUDE_BIN."
  local rc=0
  "$bin" "${REPLY_ARGS[@]}" < "$work" || rc=$?
  return "$rc"
}

# render_template <name> <base>: copy a claude-prompts template into a private file with
# [BASE] substituted. Sets REPLY to the private path.
render_template() {
  local tpl="$PROMPT_DIR/$1" base="$2" work
  require_file "$tpl"
  require_no_newline "BASE" "$base"
  mk_private; work="$REPLY"
  cat "$tpl" > "$work"
  subst_into "$work" "BASE" "$base"
  REPLY="$work"
}

cmd_task() {
  task_assemble_prompt "$@"
  run_claude "$REPLY" "$TASK_DRY_RUN"
}

cmd_review() {
  local base="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "review: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "review: --base is required"
  render_template code-review.md "$base"
  local work="$REPLY"
  assert_no_residual "$work"
  run_claude "$work" "$dry"
}

cmd_adversarial() {
  local base="" focus="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --focus) focus="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "adversarial: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "adversarial: --base is required"
  [ -n "$focus" ] || die "adversarial: --focus is required"
  require_file "$focus"
  render_template adversarial-review.md "$base"
  local work="$REPLY"
  # [USER_FOCUS] is the only placeholder allowed to survive [BASE] substitution. The focus
  # text goes in afterwards and is NOT re-checked, so brackets inside it are kept verbatim.
  assert_no_residual "$work" "USER_FOCUS"
  local focus_text; focus_text="$(cat "$focus")"
  subst_into "$work" "USER_FOCUS" "$focus_text"
  run_claude "$work" "$dry"
}

main() {
  [ $# -ge 1 ] || die "usage: dispatch-claude.sh {task|review|adversarial} ... [--model <alias>]"
  local sub="$1"; shift
  split_model_arg "$@"
  set -- ${REST[@]+"${REST[@]}"}
  case "$sub" in
    task)        cmd_task "$@" ;;
    review)      cmd_review "$@" ;;
    adversarial) cmd_adversarial "$@" ;;
    *) die "unknown subcommand: $sub (expected task|review|adversarial)" ;;
  esac
}
main "$@"
