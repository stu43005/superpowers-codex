#!/usr/bin/env bash
# Plain-bash tests for dispatch.sh. Hermetic: substitution/validation cases use
# --dry-run and need no live codex; version-guard cases inject DISPATCH_COMPANION.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/dispatch.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
run() { OUT="$("$D" "$@" 2>&1)"; RC=$?; }

tmp="$(mktemp -d)"
P="$tmp/plan.md";   printf 'Plan: [PLAN_FILE_PATH]\nTask: [TASK_ID]\n' > "$P"
R="$tmp/report.md"; printf 'IMPLEMENTER REPORT BODY\n' > "$R"
# Fake companion paths for hermetic version-guard tests (never executed here).
OLDC="$tmp/codex/0.9.0/scripts/codex-companion.mjs"; mkdir -p "$(dirname "$OLDC")"; : > "$OLDC"
NEWC="$tmp/codex/1.9.0/scripts/codex-companion.mjs"; mkdir -p "$(dirname "$NEWC")"; : > "$NEWC"

# 1. data-safe metachar substitution via TASK_ID (not a *_FILE_PATH key)
run task --prompt "$P" --dry-run --set PLAN_FILE_PATH="$P" --set 'TASK_ID=Task #3 & [x] \ more'
case "$OUT" in *'Task #3 & [x] \ more'*) ok "metachar value substituted literally" ;; *) bad "metachar value substituted literally" "$OUT" ;; esac
case "$OUT" in *'[PLAN_FILE_PATH]'*|*'[TASK_ID]'*) bad "no residual placeholder" "$OUT" ;; *) ok "no residual placeholder" ;; esac

# 2. missing --set (residual placeholder) -> non-zero
run task --prompt "$P" --dry-run --set PLAN_FILE_PATH="$P"
[ "$RC" -ne 0 ] && ok "missing --set -> non-zero" || bad "missing --set -> non-zero" "rc=$RC"

# 3. newline value rejected
run task --prompt "$P" --dry-run --set PLAN_FILE_PATH="$P" --set "TASK_ID=$(printf 'a\nb')"
[ "$RC" -ne 0 ] && ok "newline value rejected" || bad "newline value rejected" "rc=$RC"

# 4. nonexistent --prompt -> non-zero
run task --prompt /no/such/file --dry-run
[ "$RC" -ne 0 ] && ok "missing prompt -> non-zero" || bad "missing prompt" "rc=$RC"

# 5. nonexistent --report-file -> non-zero
run task --prompt "$P" --report-file /no/such --dry-run --set PLAN_FILE_PATH="$P" --set TASK_ID=t
[ "$RC" -ne 0 ] && ok "missing report -> non-zero" || bad "missing report" "rc=$RC"

# 6. nonexistent *_FILE_PATH --set value -> non-zero (path existence validation)
run task --prompt "$P" --dry-run --set PLAN_FILE_PATH=/no/such/plan.md --set TASK_ID=t
[ "$RC" -ne 0 ] && ok "nonexistent --set file path -> non-zero" || bad "nonexistent --set file path" "rc=$RC"

# 7. report: [REPORT_FILE_PATH] replaced by a PRIVATE copy path (contains "dispatch."),
#    source path NOT leaked, placeholder gone. Uses a prompt that actually contains the token.
PR="$tmp/withreport.md"; printf 'Plan: [PLAN_FILE_PATH]\nReport: [REPORT_FILE_PATH]\n' > "$PR"
run task --prompt "$PR" --report-file "$R" --dry-run --set PLAN_FILE_PATH="$P"
if printf '%s' "$OUT" | grep -q 'Report: .*dispatch\.' \
   && ! printf '%s' "$OUT" | grep -qF "$R" \
   && ! printf '%s' "$OUT" | grep -qF '[REPORT_FILE_PATH]'; then
  ok "report injected as private copy (placeholder replaced, source not leaked)"
else bad "report injected as private copy" "$OUT"; fi
[ -f "$R" ] && ok "source report preserved" || bad "source report preserved" "deleted"

# 8. unknown subcommand -> non-zero
run frobnicate
[ "$RC" -ne 0 ] && ok "unknown subcommand -> non-zero" || bad "unknown subcommand" "rc=$RC"

# 9. review requires --base
run review
[ "$RC" -ne 0 ] && ok "review without --base -> non-zero" || bad "review without --base" "rc=$RC"

# 10. version guard: old companion -> non-zero
OUT="$(DISPATCH_COMPANION="$OLDC" "$D" task --prompt "$P" --dry-run --set PLAN_FILE_PATH="$P" --set TASK_ID=t 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "old companion version -> non-zero" || bad "old companion version" "rc=$RC out=$OUT"

# 11. version guard: new companion -> passes (dry-run prints, exit 0)
OUT="$(DISPATCH_COMPANION="$NEWC" "$D" task --prompt "$P" --dry-run --set PLAN_FILE_PATH="$P" --set TASK_ID=t 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "new companion version -> ok" || bad "new companion version" "rc=$RC out=$OUT"

# 12. dispatch.sh never backgrounds the companion (check the node invocation lines only)
grep -Eq 'node .*--background|node .*&[[:space:]]*$' "$D" && bad "no background companion call" "found background node call" || ok "no background companion call"

rm -rf "$tmp"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
