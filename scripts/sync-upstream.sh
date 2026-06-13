#!/usr/bin/env bash
#
# sync-upstream.sh — sync a chosen SUBSET of skills from upstream obra/superpowers
#                    onto the local `vendor` branch.
#
# Design notes:
#   * Uses git plumbing only; it never runs `git checkout vendor`, so it does not
#     touch the working tree and cannot delete this script mid-run on branch switch.
#   * Only the skill directories listed in vendored-skills.txt are synced; the
#     `vendor` branch always holds exactly that subset.
#   * After syncing it stacks a new commit on `vendor` (parent = old vendor tip),
#     keeping linear history so a later `git merge vendor` into main performs a
#     real three-way merge.
#
# Usage:
#   scripts/sync-upstream.sh <upstream-tag>
#   e.g. scripts/sync-upstream.sh v5.2.0
#
# Afterwards:
#   git checkout main && git merge vendor
#   (only hunks you changed AND upstream also changed will conflict)

set -euo pipefail

TAG="${1:?usage: scripts/sync-upstream.sh <upstream-tag>  e.g. v5.2.0}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SKILLS_FILE="$REPO_ROOT/vendored-skills.txt"
[ -f "$SKILLS_FILE" ] || { echo "missing $SKILLS_FILE" >&2; exit 1; }

# Ensure the vendor branch exists.
git rev-parse --verify --quiet vendor >/dev/null \
  || { echo "vendor branch not found; create it first: git branch vendor <pristine-base>" >&2; exit 1; }

echo ">> fetching upstream tags ..."
git fetch upstream --tags

# Ensure the requested tag exists.
git rev-parse --verify --quiet "${TAG}^{commit}" >/dev/null \
  || { echo "upstream tag not found: $TAG" >&2; exit 1; }

# Build the new vendor tree in a temporary index, never touching the working tree.
TMP_INDEX="$(mktemp -t vendor-index.XXXXXX)"
trap 'rm -f "$TMP_INDEX"' EXIT
export GIT_INDEX_FILE="$TMP_INDEX"

# Start from the current vendor tree.
git read-tree vendor

while IFS= read -r skill || [ -n "$skill" ]; do
  # Skip blank lines and comments.
  case "$skill" in
    ''|\#*) continue ;;
  esac
  skill="$(printf '%s' "$skill" | tr -d '[:space:]')"
  [ -z "$skill" ] && continue

  # Make sure the upstream tag actually has this skill directory.
  if ! git rev-parse --verify --quiet "${TAG}:skills/${skill}" >/dev/null; then
    echo "!! upstream $TAG has no skills/${skill}; skipping (removed or renamed upstream?)" >&2
    continue
  fi

  # Drop the old subtree from the temp index (handles upstream deletions/renames),
  # then read in the new version of the subtree.
  git rm -r --cached --quiet --ignore-unmatch "skills/${skill}" >/dev/null
  git read-tree --prefix="skills/${skill}/" "${TAG}:skills/${skill}"
  echo "   synced skills/${skill}"
done < "$SKILLS_FILE"

NEW_TREE="$(git write-tree)"
unset GIT_INDEX_FILE

VENDOR_TIP="$(git rev-parse vendor)"

# Skip the commit if nothing changed.
CUR_TREE="$(git rev-parse 'vendor^{tree}')"
if [ "$NEW_TREE" = "$CUR_TREE" ]; then
  echo ">> vendor already matches $TAG; nothing to update."
  exit 0
fi

NEW_COMMIT="$(git commit-tree "$NEW_TREE" -p "$VENDOR_TIP" -m "vendor: sync skills from upstream $TAG")"
git update-ref refs/heads/vendor "$NEW_COMMIT"

echo
echo ">> vendor updated: $VENDOR_TIP -> $NEW_COMMIT  (from $TAG)"
echo ">> next, merge the update into your customizations:"
echo "     git checkout main && git merge vendor"
