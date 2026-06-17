#!/usr/bin/env bash
# Migration preflight: fail if a legacy skills-collection copy would shadow the
# plugin's skills. Does NOT source any SKILL.md, so it runs regardless of which
# copy "wins" skill discovery.
set -euo pipefail

SKILLS=(brainstorming writing-plans subagent-driven-development finishing-a-development-branch)

# Legacy locations to scan (overridable for tests).
if [ -n "${CLAUDE_SKILLS_DIRS:-}" ]; then
  IFS=':' read -r -a DIRS <<< "$CLAUDE_SKILLS_DIRS"
else
  DIRS=("$HOME/.claude/skills" "$HOME/.agents/skills")
fi

found=0
for d in "${DIRS[@]}"; do
  for s in "${SKILLS[@]}"; do
    p="$d/$s"
    if [ -L "$p" ]; then
      printf 'legacy skill symlink would shadow the plugin: %s -> %s\n' "$p" "$(readlink "$p")" >&2
      found=1
    elif [ -e "$p" ]; then
      printf 'legacy skill copy would shadow the plugin: %s\n' "$p" >&2
      found=1
    fi
  done
done

if [ "$found" -ne 0 ]; then
  cat >&2 <<'MSG'

A legacy skills-collection install was detected. It can shadow the plugin copy,
so the plugin's SKILL.md (and its dispatch guard) would never load.

Remove the listed paths (and any symlink targets) before using the plugin:
  rm -rf ~/.claude/skills/<name>        # and the ~/.agents/skills/<name> target
Then re-run this preflight until it passes.
MSG
  exit 1
fi

printf 'preflight OK: no legacy skill copy shadows the plugin.\n'
