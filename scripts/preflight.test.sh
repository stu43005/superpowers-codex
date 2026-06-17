#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$HERE/preflight-plugin-install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# Use a sandbox HOME so we never touch the real ~/.claude.
SBOX="$(mktemp -d)"
run() { OUT="$(HOME="$SBOX" CLAUDE_SKILLS_DIRS="$SBOX/.claude/skills:$SBOX/.agents/skills" "$P" 2>&1)"; RC=$?; }

# 1. clean sandbox (no legacy dirs) -> exit 0
mkdir -p "$SBOX/.claude/skills" "$SBOX/.agents/skills"
run
[ "$RC" -eq 0 ] && ok "clean install passes" || bad "clean install passes" "rc=$RC out=$OUT"

# 2. legacy shadow in ~/.claude/skills -> non-zero, prints the offending path
mkdir -p "$SBOX/.claude/skills/writing-plans"
run
[ "$RC" -ne 0 ] && ok "legacy shadow fails" || bad "legacy shadow fails" "rc=$RC"
case "$OUT" in *writing-plans*) ok "names the offending path" ;; *) bad "names the offending path" "$OUT" ;; esac

# 3. legacy shadow in ~/.agents/skills -> non-zero
rm -rf "$SBOX"; SBOX="$(mktemp -d)"; mkdir -p "$SBOX/.claude/skills" "$SBOX/.agents/skills/brainstorming"
run
[ "$RC" -ne 0 ] && ok "~/.agents legacy fails" || bad "~/.agents legacy fails" "rc=$RC"

# 4. symlink legacy -> non-zero, and the symlink target is named
rm -rf "$SBOX"; SBOX="$(mktemp -d)"; mkdir -p "$SBOX/.claude/skills" "$SBOX/.agents/skills" "$SBOX/target"
ln -s "$SBOX/target" "$SBOX/.claude/skills/writing-plans"
run
[ "$RC" -ne 0 ] && ok "symlink legacy fails" || bad "symlink legacy fails" "rc=$RC"
case "$OUT" in *"$SBOX/target"*) ok "names symlink target" ;; *) bad "names symlink target" "$OUT" ;; esac

rm -rf "$SBOX"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
