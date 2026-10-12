#!/usr/bin/env bash
# Plain-bash tests for dispatch-claude.sh. Hermetic: DISPATCH_CLAUDE_BIN points at a
# fake claude that records its argv (NUL-separated) and stdin; no network, no real claude.
# shellcheck disable=SC2015  # A && B || C is intentional in these one-line checks
# shellcheck disable=SC2016  # literal $ text in fixtures and the fake claude is intentional
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/dispatch-claude.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
unset ANTHROPIC_API_KEY

# Fake claude: records argv and stdin, prints a canned reply, exits with FAKE_RC.
FAKE="$tmp/fake-claude"
printf '%s\n' '#!/usr/bin/env bash' \
  ': > "$FAKE_LOG/argv"' \
  'for a in "$@"; do printf "%s\0" "$a" >> "$FAKE_LOG/argv"; done' \
  'cat > "$FAKE_LOG/stdin"' \
  'printf "FAKE CLAUDE REPLY\n"' \
  'exit "${FAKE_RC:-0}"' > "$FAKE"
chmod +x "$FAKE"
export FAKE_LOG="$tmp/log"; mkdir -p "$FAKE_LOG"
export DISPATCH_CLAUDE_BIN="$FAKE"

# run <args...>: OUT=stdout, ERR=stderr, RC=exit code; clears the fake's records first.
run() {
  rm -f "$FAKE_LOG/argv" "$FAKE_LOG/stdin"
  OUT="$("$D" "$@" 2>"$tmp/stderr")"; RC=$?
  ERR="$(cat "$tmp/stderr")"
}
# load_argv: read the fake's recorded argv into ARGV.
load_argv() {
  ARGV=()
  [ -f "$FAKE_LOG/argv" ] || return 0
  local a
  while IFS= read -r -d '' a; do ARGV+=("$a"); done < "$FAKE_LOG/argv"
}
# has_pair <flag> <value>: ARGV contains <flag> immediately followed by <value>.
has_pair() {
  local i n=${#ARGV[@]}
  for ((i=0; i<n-1; i++)); do
    [ "${ARGV[i]}" = "$1" ] && [ "${ARGV[i+1]}" = "$2" ] && return 0
  done
  return 1
}
has_arg() {
  local a
  for a in ${ARGV[@]+"${ARGV[@]}"}; do [ "$a" = "$1" ] && return 0; done
  return 1
}
stdin_has() { grep -qF -- "$1" "$FAKE_LOG/stdin" 2>/dev/null; }

NOTE='You are a single-turn, read-only reviewer invoked non-interactively. Ignore any plan-mode workflow instructions (do not write plan files, do not call ExitPlanMode or AskUserQuestion, do not launch subagents). Perform the review requested in the user prompt and end your reply exactly as the prompt'"'"'s output contract requires.'

P="$tmp/plan.md"; printf 'Plan: [PLAN_FILE_PATH]\nTask: [TASK_ID]\n' > "$P"
R="$tmp/report.md"; printf 'IMPLEMENTER REPORT BODY\n' > "$R"
PR="$tmp/withreport.md"; printf 'Plan: [PLAN_FILE_PATH]\nReport: [REPORT_FILE_PATH]\n' > "$PR"
FOCUS="$tmp/focus.md"; printf 'Check [NOT_A_PLACEHOLDER] handling & $HOME literally.\nSecond focus line.\n' > "$FOCUS"

# 1. task: rendered prompt fed via stdin, identical to dispatch.sh's rendering.
run task --prompt "$P" --set PLAN_FILE_PATH="$P" --set 'TASK_ID=Task #3 & [x] \ more'
EXPECTED="$(printf 'Plan: %s\nTask: Task #3 & [x] \\ more\n' "$P")"
if [ "$RC" -eq 0 ] && [ "$(cat "$FAKE_LOG/stdin" 2>/dev/null)" = "$EXPECTED" ]; then
  ok "task: rendered prompt fed via stdin"
else bad "task: rendered prompt fed via stdin" "rc=$RC err=$ERR stdin=$(cat "$FAKE_LOG/stdin" 2>/dev/null)"; fi
NEWC="$tmp/codex/9.9.9/scripts/codex-companion.mjs"; mkdir -p "$(dirname "$NEWC")"; : > "$NEWC"
CODEX_PROMPT="$(DISPATCH_COMPANION="$NEWC" "$HERE/dispatch.sh" task --prompt "$P" --dry-run \
  --set PLAN_FILE_PATH="$P" --set 'TASK_ID=Task #3 & [x] \ more' 2>&1 | sed '1,/^--- DRY RUN: prompt ---$/d')"
[ "$CODEX_PROMPT" = "$(cat "$FAKE_LOG/stdin" 2>/dev/null)" ] \
  && ok "task: prompt matches dispatch.sh rendering" \
  || bad "task: prompt matches dispatch.sh rendering" "codex=$CODEX_PROMPT"
[ "$OUT" = "FAKE CLAUDE REPLY" ] && ok "claude stdout streamed through" || bad "claude stdout streamed through" "out=$OUT"

# 2. task: report injected as a private copy; residual placeholder still dies.
run task --prompt "$PR" --report-file "$R" --set PLAN_FILE_PATH="$P"
if [ "$RC" -eq 0 ] && grep -q 'Report: .*dispatch\.' "$FAKE_LOG/stdin" 2>/dev/null && ! stdin_has "$R"; then
  ok "task: report injected as private copy"
else bad "task: report injected as private copy" "rc=$RC err=$ERR"; fi
run task --prompt "$P" --set PLAN_FILE_PATH="$P"
[ "$RC" -ne 0 ] && [ ! -f "$FAKE_LOG/argv" ] && ok "task: residual placeholder dies before claude" \
  || bad "task: residual placeholder dies before claude" "rc=$RC"

# 3. review: code-review prompt with [BASE] substituted, three-dot diff, no residual.
run review --base feature-base
if [ "$RC" -eq 0 ] && stdin_has 'git diff feature-base...HEAD' && ! stdin_has '[BASE]'; then
  ok "review: [BASE] substituted into three-dot diff"
else bad "review: [BASE] substituted into three-dot diff" "rc=$RC err=$ERR"; fi
stdin_has 'docs/superpowers/specs/' && stdin_has 'blocking' \
  && ok "review: prompt carries scope and severity rules" || bad "review: prompt carries scope and severity rules"
run review
[ "$RC" -ne 0 ] && ok "review without --base -> non-zero" || bad "review without --base" "rc=$RC"
run review --base "$(printf 'a\nb')"
[ "$RC" -ne 0 ] && ok "review: newline in --base rejected" || bad "review: newline in --base rejected" "rc=$RC"

# 4. adversarial: [BASE] substituted, focus text verbatim (brackets do not trip the
#    residual check), and the Verdict contract is in the prompt.
run adversarial --base feature-base --focus "$FOCUS"
if [ "$RC" -eq 0 ] && stdin_has 'git diff feature-base...HEAD' && ! stdin_has '[BASE]' && ! stdin_has '[USER_FOCUS]'; then
  ok "adversarial: [BASE] and [USER_FOCUS] substituted"
else bad "adversarial: [BASE] and [USER_FOCUS] substituted" "rc=$RC err=$ERR"; fi
stdin_has 'Check [NOT_A_PLACEHOLDER] handling & $HOME literally.' && stdin_has 'Second focus line.' \
  && ok "adversarial: bracketed focus text kept verbatim" || bad "adversarial: bracketed focus text kept verbatim"
stdin_has 'Verdict: approve' && stdin_has 'Verdict: needs-attention' \
  && ok "adversarial: verdict contract present" || bad "adversarial: verdict contract present"
run adversarial --base feature-base
[ "$RC" -ne 0 ] && ok "adversarial without --focus -> non-zero" || bad "adversarial without --focus" "rc=$RC"
run adversarial --base feature-base --focus /no/such/focus.md
[ "$RC" -ne 0 ] && ok "adversarial: missing focus file -> non-zero" || bad "adversarial: missing focus file" "rc=$RC"

# 5. read-only / isolation flag set, exactly as required, for every subcommand.
for sub in task review adversarial; do
  case "$sub" in
    task) run task --prompt "$P" --set PLAN_FILE_PATH="$P" --set TASK_ID=t ;;
    review) run review --base feature-base ;;
    adversarial) run adversarial --base feature-base --focus "$FOCUS" ;;
  esac
  load_argv
  missing=""
  [ "${ARGV[0]:-}" = "-p" ] || missing="$missing -p(first)"
  has_pair --permission-mode plan || missing="$missing --permission-mode"
  has_arg --strict-mcp-config || missing="$missing --strict-mcp-config"
  has_pair --tools "Read,Grep,Glob,Bash" || missing="$missing --tools"
  has_pair --disallowedTools "mcp__*" || missing="$missing --disallowedTools"
  has_arg --disable-slash-commands || missing="$missing --disable-slash-commands"
  has_arg --no-session-persistence || missing="$missing --no-session-persistence"
  has_pair --output-format text || missing="$missing --output-format"
  has_pair --settings '{"disableAllHooks":true}' || missing="$missing --settings"
  has_pair --max-turns 200 || missing="$missing --max-turns"
  has_pair --append-system-prompt "$NOTE" || missing="$missing --append-system-prompt"
  has_arg --model && missing="$missing unexpected--model"
  [ "${#ARGV[@]}" -eq 18 ] || missing="$missing argc=${#ARGV[@]}"
  [ -z "$missing" ] && ok "$sub: exact claude flag set, no --model" || bad "$sub: exact claude flag set" "missing:$missing rc=$RC err=$ERR"
done

# 6. --model <alias> forwarded verbatim for each subcommand (position-independent).
run task --model sonnet --prompt "$P" --set PLAN_FILE_PATH="$P" --set TASK_ID=t
load_argv
[ "$RC" -eq 0 ] && has_pair --model sonnet && [ "${#ARGV[@]}" -eq 20 ] \
  && ok "task: --model forwarded" || bad "task: --model forwarded" "rc=$RC err=$ERR"
run review --base feature-base --model opus
load_argv
[ "$RC" -eq 0 ] && has_pair --model opus && ok "review: --model forwarded" || bad "review: --model forwarded" "rc=$RC err=$ERR"
run adversarial --model opus --base feature-base --focus "$FOCUS"
load_argv
[ "$RC" -eq 0 ] && has_pair --model opus && stdin_has 'Second focus line.' \
  && ok "adversarial: --model forwarded" || bad "adversarial: --model forwarded" "rc=$RC err=$ERR"
run review --base feature-base --model
[ "$RC" -ne 0 ] && ok "--model without a value -> non-zero" || bad "--model without a value" "rc=$RC"

# 7. ANTHROPIC_API_KEY billing warning: present when non-empty, absent when unset/empty.
WARN='dispatch-claude: ANTHROPIC_API_KEY is set; claude -p will bill the API key'
rm -f "$FAKE_LOG/argv"
OUT="$(ANTHROPIC_API_KEY=sk-test "$D" review --base feature-base 2>"$tmp/stderr")"; RC=$?
[ "$RC" -eq 0 ] && grep -qxF "$WARN" "$tmp/stderr" && ok "API key set -> warning" || bad "API key set -> warning" "rc=$RC err=$(cat "$tmp/stderr")"
OUT="$(ANTHROPIC_API_KEY='' "$D" review --base feature-base 2>"$tmp/stderr")"; RC=$?
! grep -qF 'ANTHROPIC_API_KEY' "$tmp/stderr" && ok "API key empty -> no warning" || bad "API key empty -> no warning"
run review --base feature-base
! printf '%s' "$ERR" | grep -qF 'ANTHROPIC_API_KEY' && ok "API key unset -> no warning" || bad "API key unset -> no warning" "$ERR"

# 8. claude executable not found -> non-zero.
rm -f "$FAKE_LOG/argv"
OUT="$(DISPATCH_CLAUDE_BIN="$tmp/no-such-claude" "$D" review --base feature-base 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "missing claude -> non-zero" || bad "missing claude -> non-zero" "rc=$RC out=$OUT"

# 9. claude's own exit code is propagated.
rm -f "$FAKE_LOG/argv"
OUT="$(FAKE_RC=7 "$D" review --base feature-base 2>/dev/null)"; RC=$?
[ "$RC" -eq 7 ] && [ "$OUT" = "FAKE CLAUDE REPLY" ] && ok "claude exit code propagated" || bad "claude exit code propagated" "rc=$RC out=$OUT"

# 10. --dry-run prints the command and rendered prompt without executing claude.
for sub in task review adversarial; do
  case "$sub" in
    task) run task --prompt "$P" --set PLAN_FILE_PATH="$P" --set TASK_ID=dry-task --dry-run --model haiku ;;
    review) run review --base dry-base --dry-run ;;
    adversarial) run adversarial --base dry-base --focus "$FOCUS" --dry-run ;;
  esac
  if [ "$RC" -eq 0 ] && [ ! -f "$FAKE_LOG/argv" ] \
     && printf '%s' "$OUT" | grep -qF -- '--- DRY RUN: command ---' \
     && printf '%s' "$OUT" | grep -qF -- '--permission-mode plan' \
     && printf '%s' "$OUT" | grep -qF -- '--- DRY RUN: prompt ---'; then
    ok "$sub --dry-run: prints command, does not execute claude"
  else bad "$sub --dry-run" "rc=$RC out=$OUT err=$ERR"; fi
done
run task --prompt "$P" --set PLAN_FILE_PATH="$P" --set TASK_ID=dry-task --dry-run --model haiku
printf '%s' "$OUT" | grep -qF 'Task: dry-task' && printf '%s' "$OUT" | grep -qF -- '--model haiku' \
  && ok "task --dry-run: shows prompt and --model" || bad "task --dry-run: shows prompt and --model" "$OUT"
run adversarial --base dry-base --focus "$FOCUS" --dry-run
printf '%s' "$OUT" | grep -qF 'git diff dry-base...HEAD' && printf '%s' "$OUT" | grep -qF '[NOT_A_PLACEHOLDER]' \
  && ok "adversarial --dry-run: shows rendered prompt" || bad "adversarial --dry-run: shows rendered prompt" "$OUT"

# 11. unknown subcommand / no subcommand -> non-zero.
run frobnicate
[ "$RC" -ne 0 ] && ok "unknown subcommand -> non-zero" || bad "unknown subcommand" "rc=$RC"
run
[ "$RC" -ne 0 ] && ok "no subcommand -> non-zero" || bad "no subcommand" "rc=$RC"

# 12. With DISPATCH_CLAUDE_BIN unset, `claude` is resolved from PATH (fake one placed first).
PBIN="$tmp/pathbin"; mkdir -p "$PBIN"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "path-claude\n" > "$FAKE_LOG/path-invoked"' \
  'printf "%s" "${ANTHROPIC_API_KEY-__UNSET__}" > "$FAKE_LOG/seen-key"' \
  'cat > /dev/null' \
  'printf "PATH CLAUDE REPLY\n"' > "$PBIN/claude"
chmod +x "$PBIN/claude"
rm -f "$FAKE_LOG/path-invoked" "$FAKE_LOG/argv"
OUT="$(env -u DISPATCH_CLAUDE_BIN PATH="$PBIN:$PATH" "$D" review --base feature-base 2>"$tmp/stderr")"; RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "PATH CLAUDE REPLY" ] && [ "$(cat "$FAKE_LOG/path-invoked" 2>/dev/null)" = "path-claude" ] \
  && [ ! -f "$FAKE_LOG/argv" ] \
  && ok "DISPATCH_CLAUDE_BIN unset -> claude resolved from PATH" \
  || bad "DISPATCH_CLAUDE_BIN unset -> claude resolved from PATH" "rc=$RC out=$OUT err=$(cat "$tmp/stderr")"

# 13. ANTHROPIC_API_KEY is passed through unchanged to the claude child (not unset).
rm -f "$FAKE_LOG/seen-key"
OUT="$(env -u DISPATCH_CLAUDE_BIN ANTHROPIC_API_KEY=sk-passthrough-123 PATH="$PBIN:$PATH" "$D" review --base feature-base 2>"$tmp/stderr")"; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$FAKE_LOG/seen-key" 2>/dev/null)" = "sk-passthrough-123" ] \
  && ok "ANTHROPIC_API_KEY passed through unchanged to claude" \
  || bad "ANTHROPIC_API_KEY passed through unchanged to claude" "rc=$RC seen=$(cat "$FAKE_LOG/seen-key" 2>/dev/null) err=$(cat "$tmp/stderr")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
