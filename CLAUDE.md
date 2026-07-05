# CLAUDE.md — superpowers-codex project rules

## Commit message type classification

This repo is a Claude Code plugin. Before picking a Conventional Commits type, **first decide whether the changed files are part of the plugin's shipped product or part of the tooling used to develop the plugin** — the two are classified in opposite ways.

### `skills/**` and `scripts/**` are the plugin's product code, not documentation

Everything under `skills/` (including `skills/**/*.md`, **especially each skill's `SKILL.md` and the reviewer/implementer prompt and focus `.md` files**), together with the review wrappers under `scripts/`, is the plugin's **shipped functionality**. They happen to be Markdown / shell, but they are **code**: a skill's instructions, flow, and reviewer prompts *are* the plugin's runtime behavior.

So when changing `skills/**` or `scripts/**`, **do NOT default to `docs:`**. Pick the type from what the change actually does — whether it alters the plugin's behavior or capability:

| The change | Type |
|---|---|
| Add a skill, or add a new step / capability / constraint to an existing skill (alters what the agent does) | `feat:` |
| Fix a wrong instruction, remove wording that causes incorrect behavior, fix a wrapper bug | `fix:` |
| Restructure / reword / split-merge with no behavior change (behavior-equivalent) | `refactor:` |
| Make the agent cheaper in tokens / faster to converge without changing the flow's behavior | `refactor:` (or `perf:` when apt) |
| Add or adjust a wrapper or its tests | As applies: `feat:` / `fix:` / `test:` |

**Reserve `docs:` for genuine documentation**: `README`, the specs/plans under `docs/`, and purely explanatory prose that does not affect how a skill executes.

Rule of thumb (one question): "Does this change alter what the plugin's consumer — i.e. **the agent executing these skills** — sees in behavior, flow, or capability?"
- Yes → `feat:` / `fix:` / `refactor:` etc., chosen by the nature of the change;
- Purely adds prose for a **human** reader without affecting skill execution → `docs:`.

> Example: adding a rule like "must run in the foreground, never `run_in_background`" to the review-dispatch section of `skills/*/SKILL.md` **constrains how the agent executes** the skill — it changes the skill's behavioral contract → `feat:` (new constraint) or `fix:` (correcting misuse), **not `docs:`**.

### `.claude/skills/**` is development-time tooling, not plugin functionality

`.claude/skills/` (e.g. `bump-version`) holds skills **used while developing this plugin**, not skills the plugin ships to its users. Changing them is **not a plugin feature change**:

- **Do NOT use `feat:`** — that would make the changelog / version inference wrongly think the plugin gained user-facing functionality.
- Use `chore:` (dev tooling / process), or `fix:` / `refactor:` as appropriate.
- Such changes **should not trigger a MINOR version bump** of the plugin (cf. the `bump-version` skill's inference: they are not new user-facing functionality).

Likewise, other pure development-support files (settings under `.claude/`, dev scripts, CI config) go under `chore:` / `fix:` / `ci:`, never `feat:`.

### Quick reference

- `skills/**`, `scripts/**` → **treat as code**; pick `feat`/`fix`/`refactor`/`test` by behavior change — never blindly `docs`.
- `.claude/skills/**`, `.claude/**` dev tooling → **not plugin functionality**; use the `chore` family, never `feat`.
- `docs:` only for `README` / `docs/` / prose written for humans.
