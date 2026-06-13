# superpowers-codex

A trimmed set of skills cherry-picked from [obra/superpowers](https://github.com/obra/superpowers),
with local customizations (e.g. removing worktree / executing-plans steps), kept in sync
with upstream over time.

> Distribution form: a plain skills collection (not a Claude Code plugin, no
> `.claude-plugin/` manifest). The repo only contains the chosen subset of skills,
> not the entire upstream tree.

## Vendored skills

Defined by [`vendored-skills.txt`](./vendored-skills.txt) (single source of truth):

- `brainstorming`
- `finishing-a-development-branch`
- `subagent-driven-development`
- `writing-plans`

Currently synced from upstream: **v5.1.0**

## Maintenance model: vendor branch + three-way merge

The key idea is to keep the "pristine upstream copy" and the "local customizations"
on separate tracks:

```
upstream/obra/superpowers  ──(subset only)──▶  vendor branch (pristine upstream subset)
                                                     │  merge
                                                     ▼
                                                  main branch (vendor subset + your edits)
```

- **`vendor` branch**: contains only the skills listed in `vendored-skills.txt`, copied
  verbatim from a specific upstream tag. It is the common ancestor (merge-base) used for
  every three-way merge.
- **`main` branch**: merged down from `vendor`, plus your local edits. This is what you
  publish.

Because `vendor` is an ancestor of `main`, updates use a real three-way merge — **only the
hunks you changed AND upstream also changed will conflict**; everything else merges
automatically.

> The `vendor` branch deliberately holds only the skill subset — it does not carry
> `README.md`, `scripts/`, or `vendored-skills.txt`. Those maintenance files live on
> `main` only, so merges never drag them around.

## Updating to a new upstream release

When upstream ships a new release (e.g. `v5.2.0`):

```bash
# 1. Sync the vendor branch to the new upstream tag (subset only; never switches branch)
scripts/sync-upstream.sh v5.2.0

# 2. Merge the upstream update into your customizations
git checkout main
git merge vendor

# 3. Resolve conflicts (if any) and commit. Conflicts only happen where you edited
#    AND upstream edited the same hunk. Remember to bump the version line above.
```

How `scripts/sync-upstream.sh` works: it assembles a new vendor tree from the upstream
tag's chosen skill subtrees using a temporary index (git plumbing), then stacks it onto
`vendor` with `commit-tree`. It **never touches the working tree or switches branches**,
so the script can't delete itself on checkout.

## Adding / removing a vendored skill

1. Edit [`vendored-skills.txt`](./vendored-skills.txt) to add or remove a skill directory name.
2. **Add**: run `scripts/sync-upstream.sh <current-tag>` to pull the skill from upstream into
   `vendor`, then `git checkout main && git merge vendor`.
3. **Remove**: on `main`, run `git rm -r skills/<name>` and commit. (Leaving the old copy on
   `vendor` is harmless — the sync script just stops touching it.)

## How this layout was first created (for reference; not normally rerun)

```bash
git remote add upstream https://github.com/obra/superpowers.git
git fetch upstream --tags
# Create vendor from a commit whose subset is byte-identical to an upstream tag.
git branch vendor <pristine-subset-commit>
```
