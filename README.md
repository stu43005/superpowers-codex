# superpowers-codex

A trimmed set of skills cherry-picked from [obra/superpowers](https://github.com/obra/superpowers),
with local customizations (e.g. removing worktree / executing-plans steps), kept in sync
with upstream over time.

> Distribution form: a Claude Code **plugin** (with `.claude-plugin/plugin.json` and a
> `.claude-plugin/marketplace.json`). Skills under `skills/<name>/` are auto-discovered;
> reviewers are dispatched through the bundled `scripts/dispatch.sh` via
> `${CLAUDE_PLUGIN_ROOT}`.

## Install

Run these inside Claude Code (they are slash commands, not shell commands):

```
/plugin marketplace add stu43005/superpowers-codex
/plugin install superpowers-codex
```

## Migrating from a skills-collection install

Earlier versions were dropped into `~/.claude/skills/`. A leftover copy can **shadow** the
plugin, so its `SKILL.md` (and the dispatch invocations inside it) would never load. Claude Code
has **no install-time hook**, so the plugin cannot run this for you — you MUST do it manually
after `/plugin install`. (`${CLAUDE_PLUGIN_ROOT}` is only expanded inside loaded SKILL.md
content, **not** in your shell, so locate the bundled script by path.)

```bash
# 1. Remove legacy copies AND any ~/.agents/skills symlink targets
rm -rf ~/.claude/skills/{brainstorming,writing-plans,subagent-driven-development,finishing-a-development-branch}
rm -rf ~/.agents/skills/{brainstorming,writing-plans,subagent-driven-development,finishing-a-development-branch}

# 2. Locate the installed preflight in the plugin cache and run it (fails if any legacy copy remains)
PF="$(ls -d ~/.claude/plugins/cache/*/superpowers-codex/*/scripts/preflight-plugin-install.sh 2>/dev/null | sort | tail -1)"
if [ -z "$PF" ]; then echo "plugin not installed; run '/plugin install superpowers-codex' first" >&2; else "$PF"; fi   # preserves the preflight's non-zero exit on a real shadow

# 3. Deterministic post-install check: the plugin copy resolves under the plugin cache and
#    no legacy skill dir remains
ls -d ~/.claude/plugins/cache/*/superpowers-codex/*/skills/writing-plans >/dev/null 2>&1 \
  && echo "OK: plugin skill present" || echo "FAIL: plugin skill not found in cache"
for s in brainstorming writing-plans subagent-driven-development finishing-a-development-branch; do
  for d in ~/.claude/skills/$s ~/.agents/skills/$s; do
    [ -e "$d" ] || [ -L "$d" ] && echo "FAIL: legacy copy still present: $d"
  done
done
```

The preflight exits non-zero and names any offending path. **Deterministic completion
criterion:** the preflight passes (no legacy copy in either location) AND the plugin's skill
directory is present under the cache (the checks above). With no legacy copy left to shadow
them, the plugin's `SKILL.md` files are necessarily what load for these skills.

As a secondary check that `${CLAUDE_PLUGIN_ROOT}` inline-expands at skill-load time, **invoke
any bundled skill once** and read the loaded skill text shown in context: its **Dispatch
mechanism** block must show an **absolute** `…/plugins/cache/…/scripts/dispatch.sh` path
(expansion worked), not a literal `${CLAUDE_PLUGIN_ROOT}`. (Do not try to read a `dispatch.sh`
path out of `--dry-run` output — that output is the `node <companion> …` command, and
`<companion-unresolved>` means codex is not set up, not that a legacy copy shadows the plugin.)

Migration is complete once the preflight passes, the cache-present / no-legacy checks pass,
and a bundled skill's loaded Dispatch mechanism block shows the inline-expanded absolute path.

### Skill discovery precedence (measured)

Measured on Claude Code 2.1.177. Skill discovery is resolved at session start, so the bare
`/<name>` precedence under coexistence cannot be sampled mid-session; it is also **not relied
upon**, because the mandatory preflight makes legacy removal a hard prerequisite. What is
deterministically verified:

- The preflight (`scripts/preflight-plugin-install.sh`) detects and **blocks** a legacy copy in
  **both** `~/.claude/skills/<name>` and `~/.agents/skills/<name>` — each makes it exit non-zero
  and name the offending path; with no legacy copy present it exits `0`.
- The namespaced `superpowers-codex:<name>` reliably loads the plugin copy: its
  `${CLAUDE_PLUGIN_ROOT}` inline-expands to an absolute path at load time.

Therefore legacy copies in **both** locations MUST be removed before relying on the plugin; once
they are gone the plugin's `SKILL.md` is the only copy of each skill that can load.

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
