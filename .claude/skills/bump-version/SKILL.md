---
name: bump-version
description: Cut a new release of the superpowers-codex plugin — bump the version in .claude-plugin/plugin.json, commit it, create an annotated git tag, and push. Use this whenever the user says "bump version", "cut a release", "release a new version", "tag a new version", "發布新版本", "出一版", or otherwise wants to publish the next version of THIS repo. Infers the next version from the commits since the last release, then confirms with the user before committing and before pushing.
---

# Bump Version (superpowers-codex release cut)

Release the next version of this plugin in one guided flow: **bump → commit → tag → push**. The version is inferred from the commits accumulated since the last release, proposed to the user for confirmation, then committed, tagged with an annotated tag, and pushed only after the user approves.

This skill is specific to the `superpowers-codex` repo. Its facts are fixed:

- **Version file:** `.claude-plugin/plugin.json`, the top-level `"version"` field (SemVer `MAJOR.MINOR.PATCH`).
- **Tag format:** annotated tag `vX.Y.Z` with message `vX.Y.Z — <short thematic summary>` (em dash, matching this fork's own history — e.g. `v0.2.0 — parallel reviewer batch dispatch`).
- **Release branch:** `main`.
- **Commit message:** `chore: bump version to X.Y.Z` — matching this repo's prior bump commits (`chore: bump version to 0.2.0`, `chore: bump version to 0.2.1`).

## The release line vs. vendored upstream tags

This repo carries **two** tag families. The fork's own releases are the `v0.x` line (`v0.2.0`, `v0.2.1`, …). The high-numbered tags (`v4.x`, `v5.x`) are **vendored upstream** tags from `obra/superpowers` and are NOT this plugin's releases.

So never anchor to `git tag --sort=-v:refname | head` — that returns an upstream tag. **Always anchor the release to the version currently in `plugin.json`:** the last release tag is `v<current-version>`, and the commits to analyze are those between that tag and `HEAD`.

## Step 1 — Read state and locate the base

Gather in parallel:

```bash
# current version (the anchor)
grep '"version"' .claude-plugin/plugin.json
git branch --show-current
git status --porcelain
```

Let `CURRENT` be the version string from `plugin.json` (e.g. `0.2.1`). The base tag is `v$CURRENT`.

Verify the base tag exists and read what has landed since:

```bash
git rev-parse -q --verify "refs/tags/v$CURRENT" >/dev/null && echo "base tag ok" || echo "base tag MISSING"
git log "v$CURRENT..HEAD" --pretty=format:"%s"
```

**Handle the preconditions before proposing anything:**

- **Not on `main`** — releases are cut from `main`. Surface this and ask whether to continue or switch.
- **Working tree not clean** — the bump commit must be atomic (only the version file). If there are unrelated uncommitted changes, stop and tell the user; do not sweep them into the release commit. If the changes ARE the thing being released, they should be committed first.
- **Base tag `v$CURRENT` missing** — the version/tag line has drifted. Fall back to `git describe --tags --abbrev=0 --match 'v[0-9]*'` to find the fork's last release, show the user what you found, and confirm the base before continuing.
- **No commits since `v$CURRENT`** — there is nothing to release. Say so and stop.

## Step 2 — Infer the next version, then confirm

Classify the commit subjects from `git log v$CURRENT..HEAD` using Conventional Commits, and map to a SemVer bump:

| Signal in the commits since the base | Bump | Example |
|---|---|---|
| A `!` after the type, or `BREAKING CHANGE:` in a body | MAJOR | `feat!: …` → `1.0.0` |
| At least one `feat:` (no breaking) | MINOR | `0.2.1` → `0.3.0` |
| Only `fix` / `docs` / `chore` / `refactor` / `perf` / `test` / `style` / `ci` / `build` | PATCH | `0.2.1` → `0.2.2` |

**Pre-1.0 caveat:** this plugin is in `0.x`, where the API is still considered unstable. A breaking change here conventionally bumps MINOR (not MAJOR), and a feature can reasonably be MINOR or PATCH. Treat the table as the default proposal, not a hard rule — the point of inferring is to save the user typing, not to remove their judgment.

Present the reasoning compactly and let the user confirm or override:

> Since `v0.2.1` there are 3 commits:
> - `docs: qualify cross-skill references …`
> - `fix: …`
> - `chore: …`
>
> Highest-impact change is a `fix`/`docs` cleanup → I suggest a **PATCH** bump: **`0.2.1 → 0.2.2`**.
> Also proposing tag summary: **`qualify cross-skill references with superpowers-codex namespace`**.
> OK to proceed, or give me a different version / summary?

The user may reply with a level (`patch`/`minor`/`major`), an explicit version (`0.3.0`), or an edited tag summary. Do not proceed until they confirm the **version** and the **tag summary** — both are part of the release and hard to change once pushed.

## Step 3 — Apply the version bump

Edit only the `"version"` field in `.claude-plugin/plugin.json` from `CURRENT` to the confirmed `NEXT`. Change nothing else in the file.

## Step 4 — Commit the bump

Commit the single changed file (`.claude-plugin/plugin.json`) on its own — the bump commit must contain only the version file, nothing else. Use this repo's established bump-commit message:

**Example:**
Input: `plugin.json` version `0.2.1` → `0.2.2`
Output: `chore: bump version to 0.2.2`

Prior bump commits in this repo, for reference:
- `chore: bump version to 0.2.0`
- `chore: bump version to 0.2.1`

## Step 5 — Create the annotated tag

After the bump commit exists, tag it:

```bash
git tag -a "v<NEXT>" -m "v<NEXT> — <confirmed summary>"
git rev-parse "v<NEXT>^{commit}"   # sanity: points at the bump commit (HEAD)
```

If `v<NEXT>` already exists, stop — the version was already released. Never move an existing tag.

## Step 6 — Confirm, then push

Pushing publishes the release, so confirm before doing it. Show exactly what will go out:

> Ready to push:
> - `git push` (main → origin/main)
> - `git push origin v<NEXT>` (new tag)
>
> Push now?

On approval:

```bash
git push
git push origin "v<NEXT>"
```

Then report the final state: the pushed commit range, the new tag, and where `origin/main` now points. If the user declines, leave the commit and tag local and tell them the exact two commands to run later (`! git push` / `! git push origin v<NEXT>`).

## Summary of the flow

1. Anchor to `v<current-version>` from `plugin.json` (never the vendored `v5.x` tags).
2. Check preconditions (on `main`, clean tree, base tag exists, commits to release).
3. Infer bump from Conventional Commits since the base → **confirm version + tag summary with the user**.
4. Edit the `version` field only.
5. Commit only the version file as `chore: bump version to X.Y.Z`.
6. Annotated tag `vX.Y.Z — <summary>` on the bump commit.
7. **Confirm, then** `git push` + `git push origin vX.Y.Z`.
