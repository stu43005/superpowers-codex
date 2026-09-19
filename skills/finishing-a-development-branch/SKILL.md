---
name: finishing-a-development-branch
description: Use when implementation is complete, all tests pass, and you need to decide how to integrate the work - guides completion of development work by presenting structured options for merge, PR, or cleanup
---

# Finishing a Development Branch

## Overview

Guide completion of development work by presenting clear options and handling chosen workflow.

**Core principle:** Verify tests → Present options → Clean up completed plans → Execute choice.

**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."

## The Process

### Step 1: Verify Tests

**Before presenting options, verify tests pass:**

```bash
# Run project's test suite
npm test / cargo test / pytest / go test ./...
```

**If tests fail:**
```
Tests failing (<N> failures). Must fix before completing:

[Show failures]

Cannot proceed with merge/PR until tests pass.
```

Stop. Don't proceed to Step 2.

**If tests pass:** Continue to Step 2.

### Step 2: Determine Base Branch

```bash
# Try common base branches
git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null
```

Or ask: "This branch split from main - is that correct?"

### Step 3: Present Options

**Present exactly these 4 options:**

```
Implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

**Don't add explanation** - keep options concise.

### Step 4: Clean Up Completed Plan Files

**Applies to Options 1 and 2 only** (the work is being integrated). Skip for Options 3 and 4.

Implementation plans under `docs/superpowers/plans/` are scaffolding for a single
development branch, not a durable record. Once the work is integrated, the plan's
content is already preserved in the commit history, so the file is dead weight that
inflates the repo and burns context on every future search.

```bash
# List plan files belonging to this branch's work
ls docs/superpowers/plans/

# Remove the plans whose implementation is complete
git rm docs/superpowers/plans/<YYYY-MM-DD-topic>.md
git commit -m "chore: remove completed plan for <topic>"
```

Commit the removal **onto the feature branch**, before the merge or PR in Step 5, so
the cleanup travels with the work it belongs to.

**Never delete `docs/superpowers/specs/`** - specs are the durable design record and
outlive the branch that implemented them. Only plans get cleaned up.

If a plan covers work that is only partially complete, keep it and say so explicitly.

### Step 5: Execute Choice

#### Option 1: Merge Locally

```bash
# Merge first — verify success before deleting anything
git checkout <base-branch>
git pull
git merge <feature-branch>

# Verify tests on merged result
<test command>
```

Then, only after merge succeeds, delete the branch:

```bash
git branch -d <feature-branch>
```

#### Option 2: Push and Create PR

```bash
# Push branch
git push -u origin <feature-branch>

# Create PR
gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets of what changed>

## Test Plan
- [ ] <verification steps>
EOF
)"
```

#### Option 3: Keep As-Is

Report: "Keeping branch <name>."

#### Option 4: Discard

**Confirm first:**
```
This will permanently delete:
- Branch <name>
- All commits: <commit-list>

Type 'discard' to confirm.
```

Wait for exact confirmation.

If confirmed:
```bash
git checkout <base-branch>
git branch -D <feature-branch>
```

## Quick Reference

| Option | Merge | Push | Cleanup Branch | Remove Completed Plan |
|--------|-------|------|----------------|-----------------------|
| 1. Merge locally | yes | - | yes | yes |
| 2. Create PR | - | yes | - | yes |
| 3. Keep as-is | - | - | - | - |
| 4. Discard | - | - | yes (force) | - |

## Common Mistakes

**Skipping test verification**
- **Problem:** Merge broken code, create failing PR
- **Fix:** Always verify tests before offering options

**Open-ended questions**
- **Problem:** "What should I do next?" is ambiguous
- **Fix:** Present exactly 4 structured options

**Merging without re-verifying tests**
- **Problem:** Merge introduces conflicts or breakage that the branch tests didn't catch
- **Fix:** Run tests on the merged result before deleting the branch

**No confirmation for discard**
- **Problem:** Accidentally delete work
- **Fix:** Require typed "discard" confirmation

**Leaving completed plans in `docs/superpowers/plans/`**
- **Problem:** Finished plans pile up as dead weight; they duplicate what the commit
  history already records and burn context on every later search
- **Fix:** Remove the plan on the feature branch before merging or opening the PR

**Deleting specs along with plans**
- **Problem:** Losing the durable design record
- **Fix:** Clean up `plans/` only; `specs/` always stays

## Red Flags

**Never:**
- Proceed with failing tests
- Merge without verifying tests on result
- Delete work without confirmation
- Force-push without explicit request
- Delete anything under `docs/superpowers/specs/`
- Remove a plan whose implementation is only partially complete

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Get typed confirmation for Option 4
- Remove the completed plan file before merging (Option 1) or opening the PR (Option 2)
