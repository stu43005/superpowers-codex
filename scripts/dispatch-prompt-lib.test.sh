#!/usr/bin/env bash
# Plain-bash tests for dispatch-prompt-lib.sh (assert_no_residual allowlist).
# shellcheck disable=SC2015  # A && B || C is intentional in these one-line checks
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }
# Runs assert_no_residual in a fresh shell so die/exit does not end this test.
check() { OUT="$(bash -c 'source "$1"; shift; assert_no_residual "$@"' _ "$HERE/dispatch-prompt-lib.sh" "$@" 2>&1)"; RC=$?; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
F="$tmp/p.md"

printf 'focus: [USER_FOCUS]\n' > "$F"
check "$F"
[ "$RC" -ne 0 ] && ok "no allowlist: residual dies" || bad "no allowlist: residual dies" "rc=$RC"

check "$F" "USER_FOCUS"
[ "$RC" -eq 0 ] && ok "allowed name is not residual" || bad "allowed name is not residual" "rc=$RC $OUT"

printf 'focus: [USER_FOCUS]\nbase: [BASE]\n' > "$F"
check "$F" "USER_FOCUS"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF '[BASE]' && ! printf '%s' "$OUT" | grep -qF '[USER_FOCUS]'; then
  ok "other residual still dies, allowed name not reported"
else bad "other residual still dies, allowed name not reported" "rc=$RC $OUT"; fi

check "$F" "USER_FOCUS BASE"
[ "$RC" -eq 0 ] && ok "multiple allowed names (space-separated)" || bad "multiple allowed names" "rc=$RC $OUT"

printf 'x: [USER_FOCUS_EXTRA]\n' > "$F"
check "$F" "USER_FOCUS"
[ "$RC" -ne 0 ] && ok "allowlist matches whole names only" || bad "allowlist matches whole names only" "rc=$RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
