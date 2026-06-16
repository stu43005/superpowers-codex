# Reviewer Dispatch Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package this skills collection as a Claude Code plugin with one shared `scripts/dispatch.sh`, slim the seven reviewer prompt files into pure sidecar bodies, and switch every reviewer to passing paths/identifiers so each reviewer reads its own inputs (no pasted bulk text), with an enforceable migration guard.

**Architecture:** A plugin manifest (`.claude-plugin/`) makes `${CLAUDE_PLUGIN_ROOT}` available for inline expansion inside SKILL.md content. A single `scripts/dispatch.sh` (subcommands `task`/`review`/`adversarial`) centralizes codex-companion resolution, a path-derived version guard, data-safe placeholder substitution, path validation, and self-contained report-file lifetime. Reviewer `*-prompt.md` files become pure prompt bodies with `[PLACEHOLDER]` tokens; Type B focus strings move to `*-focus.md` sidecars. A standalone `scripts/preflight-plugin-install.sh` (which never sources a SKILL.md) blocks migration when a legacy skills-collection copy would shadow the plugin.

**Tech Stack:** Bash (POSIX-leaning, must pass on macOS/BSD and GNU/Linux), Node-based codex companion (`codex-companion.mjs`, pinned ≥ 1.0.4), Claude Code plugin/marketplace manifests, Markdown skill docs.

**Source spec:** [docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md](../specs/2026-06-15-reviewer-dispatch-plugin-design.md)

**Research findings already established (verified against source/docs; do NOT re-investigate):**
- The codex companion (`1.0.4`) has **no** version command. Its version is only the `/codex/<ver>/scripts/codex-companion.mjs` path segment → the version guard extracts it from the resolved path.
- `task` is synchronous in the foreground unless `--background` is passed; `dispatch.sh` must never pass `--background`.
- `adversarial-review` takes the focus as **trailing positional** text; `--wait` is a boolean flag. `review` accepts `--base` + `--wait`. `task` accepts `--prompt-file`. There is no machine-readable capabilities listing (only `--help` usage text).
- **Claude Code plugins have NO install-time / post-install hook and no "plugin installed" event** (verified against the plugins reference). Therefore the preflight **cannot** be auto-run by `/plugin install`; the migration gate is a **mandatory manual preflight + a deterministic post-install verification command** (spec §3.1 fallback branch). No preflight hook is declared in `plugin.json`.
- **Skill discovery precedence (plugin-provided vs `~/.claude/skills/<name>`) is undocumented**; plugin skills are namespaced (`superpowers-codex:<name>`) while plain skills own the bare `/<name>`. The exact precedence for the bare name is determined empirically in Task 15 (legitimate operational verification — not answerable from docs).
- **`sort -V` is verified working on the target darwin** (Apple `sort` 2.3), but for portability the version *comparison* in `dispatch.sh` uses pure-bash arithmetic (no `sort -V` dependency).

---

## File Structure

**New files (top-level, main branch only — merge-safe additions):**
- `.claude-plugin/plugin.json` — plugin manifest (name/description/version/author).
- `.claude-plugin/marketplace.json` — marketplace manifest listing this single plugin (`source: "./"`).
- `scripts/dispatch.sh` — shared reviewer dispatcher (the core artifact).
- `scripts/preflight-plugin-install.sh` — legacy-shadow detector / migration gate.
- `scripts/dispatch.test.sh` — plain-bash test runner for `dispatch.sh` (uses `--dry-run`, no live codex).
- `scripts/preflight.test.sh` — plain-bash test runner for the preflight script.
- `skills/brainstorming/adversarial-spec-review-focus.md` — Type B focus sidecar.
- `skills/subagent-driven-development/final-code-reviewer-focus.md` — Type B focus sidecar.

**Modified files:**
- `skills/writing-plans/plan-document-reviewer-prompt.md` — slim to sidecar body (Type A).
- `skills/writing-plans/coverage-verifier-prompt.md` — slim to sidecar body (Type A).
- `skills/brainstorming/spec-document-reviewer-prompt.md` — slim to sidecar body (Type A).
- `skills/subagent-driven-development/spec-reviewer-prompt.md` — slim to sidecar body (Type A).
- `skills/subagent-driven-development/code-quality-reviewer-prompt.md` — convert to human-facing support doc (Type B, no sidecar).
- `skills/brainstorming/adversarial-spec-review-prompt.md` — convert to doc + focus sidecar (Type B).
- `skills/subagent-driven-development/final-code-reviewer-prompt.md` — convert to doc + focus sidecar (Type B).
- `skills/writing-plans/SKILL.md` — dispatch via `dispatch.sh`.
- `skills/brainstorming/SKILL.md` — dispatch via `dispatch.sh`.
- `skills/subagent-driven-development/SKILL.md` — dispatch via `dispatch.sh` + `--report-file` step.
- `README.md` — distribution form + install/migration sections.

**Untouched (explicit non-goal):** `skills/subagent-driven-development/implementer-prompt.md`.

**Note on dispatching the new reviewers during this plan's own review/implementation:** the existing reviewer templates use a BSD-broken `sed -i`. When dispatching reviewers manually on macOS, bake paths directly into the prompt (no `sed`), exactly as was done during this plan's spec review.

---

### Task 1: Plugin manifests

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create the directory and write `plugin.json`**

Run: `mkdir -p .claude-plugin` (the directory is new in this repo). Then write `.claude-plugin/plugin.json`:

```json
{
  "name": "superpowers-codex",
  "description": "Trimmed superpowers skills (brainstorming, writing-plans, subagent-driven-development, finishing-a-development-branch) with codex-companion reviewer dispatch.",
  "version": "0.1.0",
  "author": { "name": "Shiaupiau" }
}
```

- [ ] **Step 2: Write `marketplace.json`**

This repo is a single plugin whose root IS the plugin root, so `source` is `"./"`. (Task 15 verifies this resolves after a real `/plugin install`; if the installer requires a subdirectory layout, adjust there.)

```json
{
  "name": "superpowers-codex",
  "owner": { "name": "Shiaupiau" },
  "plugins": [
    {
      "name": "superpowers-codex",
      "source": "./",
      "description": "Trimmed superpowers skills with codex-companion reviewer dispatch."
    }
  ]
}
```

- [ ] **Step 3: Validate JSON**

Run: `node -e "JSON.parse(require('fs').readFileSync('.claude-plugin/plugin.json','utf8')); JSON.parse(require('fs').readFileSync('.claude-plugin/marketplace.json','utf8')); console.log('OK')"`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "feat: add plugin and marketplace manifests"
```

---

### Task 2: Shared `scripts/dispatch.sh`

This is the core artifact. It must run on macOS (BSD) and Linux (GNU). TDD via `--dry-run` (which never invokes codex).

> **Spec §4.2 realization.** The spec says to obtain the companion version via a "version command" and assert a minimum. Research found the companion exposes **no** version command, so this plan realizes §4.2's intent by deriving the version from the resolved `/codex/<ver>/` install-path segment (and `die`ing if it cannot be derived or is below the minimum). This is the spec's deferred "plan deliverable", not a scope change.
>
> **Fallback vs. version guard (resolving an apparent §4.2 tension).** §4.2 asks to keep the marketplace fallback *resolution* AND to exit non-zero when the version cannot be obtained. The fallback path has no `/codex/<ver>/` segment, so both clauses meet there. This plan honors the explicit hard requirement: `resolve_companion` still returns the fallback path, but `check_companion_version` `die`s on any path whose version cannot be derived (including that fallback), with a `/codex:setup` pointer. An unverifiable companion is never run; the user installs a versioned cache copy via `/codex:setup`. (Versioned cache paths — the normal case — are asserted against the minimum.)

**Files:**
- Create: `scripts/dispatch.sh`
- Test: `scripts/dispatch.test.sh`

- [ ] **Step 1: Write the failing test runner**

Create `scripts/dispatch.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/dispatch.test.sh`
Expected: FAIL (dispatch.sh does not exist yet — runner errors / all cases fail).

- [ ] **Step 3: Write `scripts/dispatch.sh`**

```bash
#!/usr/bin/env bash
# Shared reviewer dispatch for the superpowers-codex plugin.
# Subcommands: task | review | adversarial
set -euo pipefail

# Pinned minimum codex companion version (calibrated to installed 1.0.4).
# The companion exposes no version command; version is read from its install path.
# Override the resolved companion for tests with DISPATCH_COMPANION.
MIN_COMPANION_VERSION="1.0.4"

err()  { printf '%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- cleanup: delete ONLY temp files this process created ---
_PRIVATE=()
cleanup() {
  local f
  [ "${#_PRIVATE[@]}" -gt 0 ] || return 0
  for f in "${_PRIVATE[@]}"; do
    [ -n "$f" ] && rm -f "$f"
  done
  return 0
}
trap cleanup EXIT INT TERM
# Sets REPLY to a freshly-created temp path and tracks it for cleanup.
# Must NOT be called inside a command substitution — that runs in a subshell and
# would lose the _PRIVATE array update, leaking the temp file.
mk_private() {
  REPLY="$(mktemp "${TMPDIR:-/tmp}/dispatch.XXXXXX")"
  _PRIVATE+=("$REPLY")
}

# --- pure-bash version compare (no `sort -V`; portable to bash 3.2 / BSD) ---
# ver_ge A B  -> exit 0 iff dotted-numeric A >= B
ver_ge() {
  local -a A B; local i n x y
  IFS=. read -ra A <<< "$1"; IFS=. read -ra B <<< "$2"   # split on dots (ShellCheck-clean)
  n=${#A[@]}; [ "${#B[@]}" -gt "$n" ] && n=${#B[@]}
  for ((i=0; i<n; i++)); do
    x=${A[i]:-0}; y=${B[i]:-0}
    x=${x//[!0-9]/}; y=${y//[!0-9]/}      # drop any pre-release suffix chars
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    ((x>y)) && return 0
    ((x<y)) && return 1
  done
  return 0
}

# --- companion resolution (no `ls|sort -V`; pick max version in pure bash) ---
# Prints the resolved companion path, or "" if none found. Honors DISPATCH_COMPANION.
resolve_companion() {
  if [ -n "${DISPATCH_COMPANION:-}" ]; then printf '%s' "$DISPATCH_COMPANION"; return 0; fi
  local best="" best_ver="" c v
  for c in "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs; do
    [ -f "$c" ] || continue                 # unmatched glob stays literal -> skipped
    v="${c#*/codex/}"; v="${v%%/*}"
    if [ -z "$best" ] || ver_ge "$v" "$best_ver"; then best="$c"; best_ver="$v"; fi
  done
  if [ -z "$best" ]; then
    local fb="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
    [ -f "$fb" ] && best="$fb"
  fi
  printf '%s' "$best"
}
require_companion() {                       # prints path or dies
  local c; c="$(resolve_companion)"
  [ -n "$c" ] || die "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review."
  printf '%s' "$c"
}

# --- version guard: read version from the .../codex/<ver>/scripts/... path segment ---
check_companion_version() {
  local companion="$1" ver=""
  case "$companion" in
    */codex/*/scripts/codex-companion.mjs)
      ver="${companion#*/codex/}"; ver="${ver%%/*}" ;;
  esac
  case "$ver" in
    [0-9]*)                                 # versioned cache path -> assert minimum
      ver_ge "$ver" "$MIN_COMPANION_VERSION" || \
        die "codex companion $ver < required $MIN_COMPANION_VERSION; run /codex:setup to update codex." ;;
    *)                                      # version cannot be derived (e.g. the un-versioned
      # marketplace fallback path): hard stop — never run an unverifiable companion. Resolution
      # still keeps the fallback path, but the user must run /codex:setup for a versioned copy.
      die "cannot determine codex companion version from ($companion); run /codex:setup to install a versioned codex." ;;
  esac
}

is_file_path_key() { case "$1" in *_FILE_PATH) return 0 ;; *) return 1 ;; esac; }

# --- data-safe literal substitution: [KEY] -> VALUE (no regex/sed metachar hazard) ---
require_no_newline() {
  case "$2" in
    *$'\n'*) die "--set $1 value must not contain a newline" ;;
  esac
}
subst_into() {            # subst_into <file> <KEY> <VALUE>
  local file="$1" key="$2" val="$3" content
  content="$(cat "$file"; printf x)"; content="${content%x}"   # preserve trailing newlines
  content="${content//"[$key]"/"$val"}"
  printf '%s' "$content" > "$file"
}
assert_no_residual() {    # assert_no_residual <file>
  if grep -Eq '\[[A-Z_][A-Z0-9_]*\]' "$1"; then
    err "unsubstituted placeholder(s) remain:"
    grep -Eo '\[[A-Z_][A-Z0-9_]*\]' "$1" | sort -u >&2
    die "provide a --set for each placeholder."
  fi
}

require_file() { [ -f "$1" ] || die "file not found: $1 (cwd=$(pwd))"; }

cmd_task() {
  local prompt="" report_src="" dry=0
  local -a set_keys=() set_vals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --report-file) report_src="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --set)
        local kv="$2"; shift 2
        set_keys+=("${kv%%=*}"); set_vals+=("${kv#*=}") ;;
      *) die "task: unknown arg: $1" ;;
    esac
  done
  [ -n "$prompt" ] || die "task: --prompt is required"
  require_file "$prompt"
  [ -z "$report_src" ] || require_file "$report_src"

  # Validate inputs first (fail loudly before building anything):
  #   - reject newline values; - every *_FILE_PATH --set value must exist.
  local i
  if [ "${#set_keys[@]}" -gt 0 ]; then
    for i in "${!set_keys[@]}"; do
      require_no_newline "${set_keys[$i]}" "${set_vals[$i]}"
      if is_file_path_key "${set_keys[$i]}"; then require_file "${set_vals[$i]}"; fi
    done
  fi

  local work; mk_private; work="$REPLY"
  cat "$prompt" > "$work"

  # report: copy source content into our OWN private file; inject the private path.
  if [ -n "$report_src" ]; then
    local report_priv; mk_private; report_priv="$REPLY"
    cat "$report_src" > "$report_priv"
    subst_into "$work" "REPORT_FILE_PATH" "$report_priv"
  fi

  if [ "${#set_keys[@]}" -gt 0 ]; then
    for i in "${!set_keys[@]}"; do subst_into "$work" "${set_keys[$i]}" "${set_vals[$i]}"; done
  fi
  assert_no_residual "$work"

  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    printf -- '--- DRY RUN: command ---\n'
    printf 'node %q task --prompt-file %q\n' "${c:-<companion-unresolved>}" "$work"
    printf -- '--- DRY RUN: prompt ---\n'
    cat "$work"
    return 0
  fi
  local companion; companion="$(require_companion)"
  check_companion_version "$companion"
  # Runs in the foreground (no '&', no detach flag) so temp files outlive the reviewer.
  node "$companion" task --prompt-file "$work"
}

cmd_review() {
  local base="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "review: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "review: --base is required"
  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    printf 'node %q review --base %q --wait\n' "${c:-<companion-unresolved>}" "$base"; return 0
  fi
  local companion; companion="$(require_companion)"; check_companion_version "$companion"
  node "$companion" review --base "$base" --wait
}

cmd_adversarial() {
  local base="" focus="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --focus) focus="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) die "adversarial: unknown arg: $1" ;;
    esac
  done
  [ -n "$base" ] || die "adversarial: --base is required"
  [ -n "$focus" ] || die "adversarial: --focus is required"
  require_file "$focus"
  local focus_text; focus_text="$(cat "$focus")"
  if [ "$dry" -eq 1 ]; then
    local c; c="$(resolve_companion)"; [ -z "$c" ] || check_companion_version "$c"
    # focus is a trailing POSITIONAL; --wait is a boolean flag.
    printf 'node %q adversarial-review --base %q --wait %q\n' "${c:-<companion-unresolved>}" "$base" "$focus_text"; return 0
  fi
  local companion; companion="$(require_companion)"; check_companion_version "$companion"
  node "$companion" adversarial-review --base "$base" --wait "$focus_text"
}

main() {
  [ $# -ge 1 ] || die "usage: dispatch.sh {task|review|adversarial} ..."
  local sub="$1"; shift
  case "$sub" in
    task)        cmd_task "$@" ;;
    review)      cmd_review "$@" ;;
    adversarial) cmd_adversarial "$@" ;;
    *) die "unknown subcommand: $sub (expected task|review|adversarial)" ;;
  esac
}
main "$@"
```

- [ ] **Step 4: Make it executable and run static checks**

Run:

```bash
chmod +x scripts/dispatch.sh
bash -n scripts/dispatch.sh
if command -v shellcheck >/dev/null; then shellcheck scripts/dispatch.sh; else echo "shellcheck not installed; relying on bash -n + test runner"; fi
```

Expected: no syntax errors; shellcheck clean (its non-zero exit must surface, not be masked) — or, only if `shellcheck` is absent, the skip note.

- [ ] **Step 5: Run the test runner to verify it passes**

Run: `bash scripts/dispatch.test.sh`
Expected: `14 passed, 0 failed` (exit 0).

- [ ] **Step 6: Commit**

```bash
git add scripts/dispatch.sh scripts/dispatch.test.sh
git commit -m "feat: add shared dispatch.sh with data-safe subst and self-contained report lifetime"
```

---

### Task 3: `scripts/preflight-plugin-install.sh`

Detects legacy skills-collection copies that would shadow the plugin. Never sources any SKILL.md, so shadowing cannot disable it.

**Files:**
- Create: `scripts/preflight-plugin-install.sh`
- Test: `scripts/preflight.test.sh`

- [ ] **Step 1: Write the failing test runner**

Create `scripts/preflight.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/preflight.test.sh`
Expected: FAIL (script does not exist yet).

- [ ] **Step 3: Write `scripts/preflight-plugin-install.sh`**

```bash
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
```

- [ ] **Step 4: Make executable, static-check, run tests**

Run:

```bash
chmod +x scripts/preflight-plugin-install.sh
bash -n scripts/preflight-plugin-install.sh
if command -v shellcheck >/dev/null; then shellcheck scripts/preflight-plugin-install.sh; else echo "shellcheck not installed; relying on bash -n + test runner"; fi
bash scripts/preflight.test.sh
```

Expected: `bash -n` clean; shellcheck clean (or the skip note); test runner reports `6 passed, 0 failed` (exit 0).

- [ ] **Step 5: Commit**

```bash
git add scripts/preflight-plugin-install.sh scripts/preflight.test.sh
git commit -m "feat: add plugin-install preflight that blocks legacy skill shadowing"
```

---

### Task 4: Slim `plan-document-reviewer-prompt.md` to a sidecar body

**Files:**
- Modify: `skills/writing-plans/plan-document-reviewer-prompt.md`

The file becomes **only the prompt body sent to codex** — no `# ... Template` doc framing, no "How to Dispatch" bash block, no defensive prose. It must read the plan itself and use placeholders `[PLAN_FILE_PATH]`, `[SPEC_FILE_PATH]`, `[TASK_ID]`.

- [ ] **Step 1: Replace the entire file contents**

```markdown
You are an independent plan Task reviewer executed by the codex companion. You must use
rigorous judgment. Do not approve a Task that has real problems just to avoid friction.

**Plan file:** [PLAN_FILE_PATH]
**Spec file:** [SPEC_FILE_PATH]

Read the plan file in full. **Review the Task whose heading matches `[TASK_ID]`.** Treat
every other Task in the plan file as sibling context for cross-Task consistency checks.
Read the spec file in full before proceeding.

## What to Check

Review the Task under review against ALL seven criteria below. Flag any issue that would
cause an implementer to build the wrong thing, get stuck, or produce inconsistent code.

**1. Spec Coverage**
Does this Task correctly implement its corresponding spec requirement(s)?
Map every step back to a spec section. Flag any step that contradicts the spec
or any spec requirement assigned to this Task that is not addressed.

**2. Placeholder Scan**
Search for vague filler that leaves real decisions to the implementer:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases" (without showing the actual code)
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (the implementer may be executing Tasks out of order)
- Any step that describes *what* to do without showing *how* (code blocks are required for code steps)
- References to types, functions, or methods not defined anywhere in the plan

**3. Type Consistency and Cross-Task Integration Seams**
Are types, method signatures, and property names consistent between this Task and all
sibling Tasks? A function named `clearLayers()` in this Task but `clearFullLayers()` in
another Task is a latent bug. Flag every mismatch.

When this Task was edited (i.e., you are re-reviewing it after a fix), you MUST
additionally check whether the edit introduced any inconsistency or broken integration
seam with the sibling Tasks. This covers the case where a change in this Task could break
an already-passed sibling Task — you are responsible for catching that here so sibling
Tasks do not need to be re-reviewed solely for this reason. Flag every such cross-Task
breakage found.

**4. Code Completeness**
Every step that changes or creates code must contain the actual code — not a
description of what the code should do. A step like "implement the parser" with
no code block is a plan failure.

**5. Command Accuracy**
Every command must be complete and correct (right flags, right paths, right tool).
Expected output must be plausible and specific. "Expected: PASS" is acceptable;
"Expected: it works" is not.

**6. Document Reference Leak**
Code blocks and inline code comments must not reference the spec or plan documents
themselves. Examples of forbidden references:
- "per design spec §1-4"
- "see plan Task 2"
- "as described in the spec"
- "according to the implementation plan"
Code must be self-explanatory. Remove every such reference.

**7. Pre-Implementation Research Task Leak**
The plan must not contain steps or tasks that merely verify third-party library or
API behavior before implementation begins. Such research must happen *before* the
plan is written — deferring it to the implementer is a plan failure.

Forbidden examples:
- "Verify that library X's Y method accepts Z parameter"
- "Confirm the semantics of Z API call"
- "Check whether package W supports feature V"

**Distinguishing rule:** If the question can be answered by reading docs or source
code right now, it is pre-implementation research and is forbidden in the plan.
If it can only be answered by running against a real system after implementation
(e.g. `getIndexes()`, `EXPLAIN`, slow-query log, APM metrics, smoke tests,
migration before/after comparison), it is legitimate operational verification and
must NOT be removed.

## Calibration

Only flag issues that would cause real problems during implementation.
Minor wording preferences and style suggestions are not issues.
Approve a Task only when all seven criteria pass AND no cross-Task seam breakage
was found.

## Output Format

### Task [TASK_ID] Review

**Issues (if any):**
- [Criterion]: [specific issue at Step X] — [why it matters for implementation]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement that do not constitute blockers]

Your final line MUST be exactly one of:
Status: OKAY
Status: Issues Found
```

- [ ] **Step 2: Verify no dispatch scaffolding remains and placeholders are present**

Run:

```bash
F=skills/writing-plans/plan-document-reviewer-prompt.md
grep -nE 'CODEX_COMPANION|mktemp|<<.?PROMPT|How to Dispatch|--prompt-file|paste|sibling Tasks|FULL TEXT' "$F" && echo "LEFTOVER" || echo "CLEAN"
for ph in '[PLAN_FILE_PATH]' '[SPEC_FILE_PATH]' '[TASK_ID]'; do
  grep -qF "$ph" "$F" && echo "present: $ph" || echo "MISSING: $ph"
done
```

Expected: `CLEAN`, then `present:` for all three placeholders (no `MISSING`).

- [ ] **Step 3: Commit**

```bash
git add skills/writing-plans/plan-document-reviewer-prompt.md
git commit -m "refactor(writing-plans): slim plan-document-reviewer to sidecar body"
```

---

### Task 5: Slim `coverage-verifier-prompt.md` to a sidecar body

**Files:**
- Modify: `skills/writing-plans/coverage-verifier-prompt.md`

Body-only; placeholders `[PLAN_FILE_PATH]`, `[SPEC_FILE_PATH]`.

- [ ] **Step 1: Replace the entire file contents**

```markdown
You are an independent coverage verifier executed by the codex companion. You must use
rigorous judgment. Your job is to compare the ENTIRE plan against the ENTIRE spec and
identify anything in the spec that the plan fails to cover, silently changes, or weakens.

**Plan file:** [PLAN_FILE_PATH]
**Spec file:** [SPEC_FILE_PATH]

Read both files in full before proceeding.

## What to Check

**1. Spec Requirements — Item by Item**
List every functional requirement, described behavior, and acceptance criterion in
the spec. For each one, identify which Task(s) in the plan implement it. If a
requirement has no corresponding Task, list it as a coverage gap.

**2. Design Decisions — Item by Item**
List every design decision in the spec: architecture choices, data structures, API
shapes, error-handling strategy, dependency selections, performance constraints,
security requirements, compatibility constraints. For each one, confirm it is
realized in the plan. Flag anything that is:
- Missing entirely (no Task addresses it)
- Silently changed (the plan makes a different choice without acknowledging it)
- Weakened (the plan addresses it partially or makes it optional when the spec requires it)

**3. Implicit Requirements and Edge Conditions**
Identify conditions phrased in the spec with "should", "must", "need", "avoid",
"must not", or equivalent. Confirm each has a corresponding implementation step
or verification step in the plan. List any that do not.

**4. Cross-Task Integration**
Identify spec requirements that are split across multiple Tasks. Confirm there is
an integration point — a Task, step, or test — that actually connects them.
Example failure: Task A defines a type and Task B uses it, but no Task imports or
wires them together. List any disconnected splits.

**5. Out-of-Scope Content**
Identify any work in the plan that has no corresponding requirement in the spec
(scope creep). List each item so the user can decide whether to keep it.

## Calibration

Only flag issues that represent real gaps, contradictions, or scope creep.
Minor wording differences and stylistic choices between the spec and plan are not gaps.
Approve only when every spec requirement and design decision is accounted for.

## Output Format

### Coverage Verification

**Coverage Gaps (if any):**
- [Spec section / requirement]: not covered — [which Task should address it, or suggest a new Task]

**Design Decision Gaps (if any):**
- [Spec decision]: missing / changed / weakened — [details]

**Implicit Requirement Gaps (if any):**
- [Condition from spec]: no corresponding step in plan — [details]

**Cross-Task Integration Gaps (if any):**
- [Requirements split across Tasks X and Y]: missing integration point — [details]

**Out-of-Scope Content (informational, does not block approval):**
- [Plan Task / step]: not traceable to any spec requirement — [details]

Your final line MUST be exactly one of:
Status: OKAY
Status: Issues Found
```

- [ ] **Step 2: Verify clean + placeholders present**

Run:
```bash
grep -nE 'CODEX_COMPANION|mktemp|<<.?PROMPT|How to Dispatch|--prompt-file' skills/writing-plans/coverage-verifier-prompt.md && echo "LEFTOVER" || echo "CLEAN"
grep -c '\[PLAN_FILE_PATH\]\|\[SPEC_FILE_PATH\]' skills/writing-plans/coverage-verifier-prompt.md
```
Expected: `CLEAN` and non-zero count.

- [ ] **Step 3: Commit**

```bash
git add skills/writing-plans/coverage-verifier-prompt.md
git commit -m "refactor(writing-plans): slim coverage-verifier to sidecar body"
```

---

### Task 6: Slim `spec-document-reviewer-prompt.md` to a sidecar body

**Files:**
- Modify: `skills/brainstorming/spec-document-reviewer-prompt.md`

Body-only; placeholder `[SPEC_FILE_PATH]`.

- [ ] **Step 1: Replace the entire file contents**

```markdown
You are a spec document reviewer executed by the codex companion. Your job is to verify
that the spec document at the path below is structurally complete and ready for
implementation planning. Read the file, then apply each check in the table below.

**Spec to review:** [SPEC_FILE_PATH]

## What to Check

| Category | What to Look For |
|----------|------------------|
| Placeholder scan | "TBD", "TODO", blank sections, or vague requirements that are not actionable |
| Internal consistency | Sections that contradict each other; architecture descriptions that do not match feature descriptions |
| Scope check | Focused enough for a single implementation plan — not spanning multiple independent subsystems; if too broad, flag for decomposition |
| Ambiguity check | Any requirement that could be interpreted two different ways; if so, it must be made explicit |
| YAGNI | Unrequested features, over-engineering |

## Calibration

Only flag issues that would cause real problems during implementation planning.
A missing section, a contradiction, or a requirement so ambiguous it could be
interpreted two different ways — those are issues. Minor wording improvements,
stylistic preferences, and "sections less detailed than others" are not.

Approve unless there are serious gaps that would lead to a flawed plan.

## Output Format

Your response MUST end with exactly one of these two final lines (the last line of your entire response):

    Status: OKAY

or

    Status: Issues Found

If issues are found, list each one before the final Status line using this format:

**Issues:**
- [Section/area]: [specific issue] — [why it matters for planning]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement that should NOT appear in Issues]
```

- [ ] **Step 2: Verify clean + placeholder present**

Run:
```bash
grep -nE 'CODEX_COMPANION|mktemp|<<.?PROMPT|How to Dispatch|Invocation|--prompt-file' skills/brainstorming/spec-document-reviewer-prompt.md && echo "LEFTOVER" || echo "CLEAN"
grep -c '\[SPEC_FILE_PATH\]' skills/brainstorming/spec-document-reviewer-prompt.md
```
Expected: `CLEAN` and non-zero count.

- [ ] **Step 3: Commit**

```bash
git add skills/brainstorming/spec-document-reviewer-prompt.md
git commit -m "refactor(brainstorming): slim spec-document-reviewer to sidecar body"
```

---

### Task 7: Slim `spec-reviewer-prompt.md` (sdd) to a sidecar body

**Files:**
- Modify: `skills/subagent-driven-development/spec-reviewer-prompt.md`

Body-only; placeholders `[PLAN_FILE_PATH]`, `[TASK_ID]`, `[TASK_BASE]`, `[REPORT_FILE_PATH]`. The implementer report is read from `[REPORT_FILE_PATH]` (a file), not pasted.

- [ ] **Step 1: Replace the entire file contents**

```markdown
You are a spec compliance reviewer executed by the codex companion. You verify whether an
implementation matches its specification. Do NOT trust the implementer's report — read the
actual code and git history.

**Plan file:** [PLAN_FILE_PATH]
**Task under review:** the Task whose heading matches `[TASK_ID]` in the plan file.
**Implementer's report file:** [REPORT_FILE_PATH]
**Task base commit:** [TASK_BASE]

Read the plan file and locate the Task headed `[TASK_ID]` — that is the requirement set.
Read the implementer's report at `[REPORT_FILE_PATH]` to see what they CLAIM they built.

## CRITICAL: Do Not Trust the Report

The implementer may have finished quickly. Their report may be incomplete,
inaccurate, or optimistic. You MUST verify everything independently.

**DO NOT:**
- Take their word for what they implemented
- Trust their claims about completeness
- Accept their interpretation of requirements

**DO:**
- Run `git diff [TASK_BASE]..HEAD` to read the actual code changes
- Compare actual implementation to the Task's requirements line by line
- Check for missing pieces they claimed to implement
- Look for extra features they didn't mention

## How to Read the Implementation

Run this git command yourself to see exactly what was changed:

git diff [TASK_BASE]..HEAD

This is a literal two-dot range covering all commits since that base — read every file
changed and every line added or removed.

## Your Job

Read the implementation code and verify:

**Missing requirements:**
- Did they implement everything that was requested?
- Are there requirements they skipped or missed?
- Did they claim something works but didn't actually implement it?

**Extra/unneeded work:**
- Did they build things that weren't requested?
- Did they over-engineer or add unnecessary features?
- Did they add "nice to haves" that weren't in spec?

**Misunderstandings:**
- Did they interpret requirements differently than intended?
- Did they solve the wrong problem?
- Did they implement the right feature but the wrong way?

**Verify by reading code, not by trusting the report.**

## Issue Reporting Requirements

> **MANDATORY — zero exceptions:** For every issue you find, you MUST provide ALL of the following. Omitting either item is a reviewer error.
>
> 1. **Precise location** — the exact file path and line number(s) where the problem occurs (e.g. `src/foo/bar.ts:42`).
> 2. **Concrete fix** — a complete patch or directly-applicable replacement code that resolves the issue. You MUST NOT describe what should change in prose without also supplying actual code. "This function should validate X" is forbidden; a diff or replacement snippet is required.

## Output Contract

Your final output line MUST be exactly one of:

Status: OKAY
(if the implementation is fully spec-compliant after code inspection)

Status: Issues Found
(followed by each issue with its exact file:line location AND a concrete code fix — never prose-only descriptions)

No other final line format is accepted.
```

- [ ] **Step 2: Verify clean + placeholders present**

Run:
```bash
grep -nE 'CODEX_COMPANION|mktemp|<<.?PROMPT|Locate codex|--prompt-file|FULL TEXT of task' skills/subagent-driven-development/spec-reviewer-prompt.md && echo "LEFTOVER" || echo "CLEAN"
grep -c '\[PLAN_FILE_PATH\]\|\[TASK_ID\]\|\[TASK_BASE\]\|\[REPORT_FILE_PATH\]' skills/subagent-driven-development/spec-reviewer-prompt.md
```
Expected: `CLEAN` and non-zero count.

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/spec-reviewer-prompt.md
git commit -m "refactor(sdd): slim spec-reviewer to sidecar body, read report by path"
```

---

### Task 8: Convert `code-quality-reviewer-prompt.md` to a human-facing support doc

**Files:**
- Modify: `skills/subagent-driven-development/code-quality-reviewer-prompt.md`

`dispatch.sh review` consumes no prompt file, so this file carries no sidecar body — only human-facing notes.

- [ ] **Step 1: Replace the entire file contents**

```markdown
# Code Quality Reviewer — `dispatch.sh review`

Run after the spec compliance reviewer returns `Status: OKAY` for a task. Dispatched via
`dispatch.sh review --base <TASK_BASE>`, which calls the codex companion's native
`review` command. There is **no prompt sidecar** — the native reviewer owns the quality
judgment, and `review` does not read a `--prompt-file`.

**Purpose:** Let Codex's native reviewer assess code quality and surface bugs or
correctness problems in the task's diff.

`TASK_BASE` is the `git rev-parse HEAD` captured immediately before this task's implementer
started; it must be a direct ancestor of HEAD. `--base` makes the companion diff
`git diff $(git merge-base HEAD <TASK_BASE>)..HEAD`, i.e. exactly this task's commits.

## Interpreting the output (prose, not a Verdict line)

The native `review` command returns **free-form prose**, not a structured `Verdict:` line
(that field exists only for `adversarial-review`). The parent agent interprets it:

- **Any blocking-severity defect** (a bug, a clear correctness issue, a quality problem
  that would block a confident merge) → treat as **Issues Found**: extract file:line +
  recommendation, dispatch the implementer to fix all blocking issues, then re-run this
  reviewer. Repeat until no blocking findings remain.
- **No significant issues** (or only minor style notes) → treat as **OKAY**: mark the
  quality gate passed and proceed.

**Severity calibration:** "blocking" = what a senior engineer would require fixed before
merge — bugs, data-loss risks, broken error handling, security issues, missing critical
test coverage. Style preferences do not trigger a re-review loop.

**Do not ask the user** whether to re-run or proceed — the loop runs automatically until
the quality gate clears.

(The exact dispatch invocation lives in the subagent-driven-development SKILL.md.)
```

- [ ] **Step 2: Verify no dispatch scaffolding remains**

Run: `grep -nE 'CODEX_COMPANION|mktemp|node "\$CODEX_COMPANION"' skills/subagent-driven-development/code-quality-reviewer-prompt.md && echo "LEFTOVER" || echo "CLEAN"`
Expected: `CLEAN`.

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/code-quality-reviewer-prompt.md
git commit -m "refactor(sdd): convert code-quality-reviewer to human-facing support doc"
```

---

### Task 9: `adversarial-spec-review` → focus sidecar + doc

**Files:**
- Create: `skills/brainstorming/adversarial-spec-review-focus.md`
- Modify: `skills/brainstorming/adversarial-spec-review-prompt.md`

- [ ] **Step 1: Write the focus sidecar** (`adversarial-spec-review-focus.md`) — the exact focus text, no markdown framing:

```
Focus on design-level soundness and completeness of this not-yet-implemented spec. Challenge: (1) failure paths, partial failure, and rollback — what happens when any step fails mid-way; (2) concurrency and ordering assumptions — are there implicit sequencing requirements that are never stated; (3) boundary and empty states — zero items, maximum limits, empty input, first-run with no prior state; (4) compatibility and migration risk — does this design interact with existing data, APIs, or systems in ways that could break them; (5) unstated but critical assumptions — what must be true in the environment, dependencies, or caller behaviour for this design to work. Report only material design-level findings. Do not perform line-by-line wording review.
```

- [ ] **Step 2: Replace the prompt doc** (`adversarial-spec-review-prompt.md`) with human-facing notes only:

```markdown
# Adversarial Spec Review — `dispatch.sh adversarial`

Reviewer 2 of the brainstorming dual-review loop. Dispatched via
`dispatch.sh adversarial --base <SPEC_BASE> --focus <…>/adversarial-spec-review-focus.md`,
which calls the codex companion `adversarial-review` (focus text passed as the trailing
positional; `--wait` is a boolean flag). The focus text lives in
`adversarial-spec-review-focus.md`.

## Capturing SPEC_BASE

`SPEC_BASE` must be captured **before** writing/committing the spec file — it is HEAD at
that moment (the parent of the spec commit): `SPEC_BASE="$(git rev-parse HEAD)"`. Do NOT
re-capture after the spec commit; it must stay the direct ancestor so the review diffs
exactly the new spec content.

## Verdict parsing

- `Verdict: approve` → spec passes this reviewer.
- `Verdict: needs-attention` → fix every finding, then re-run BOTH Reviewer 1 and
  Reviewer 2 (they re-run together whenever any spec edit is made).

(The exact dispatch invocation lives in the brainstorming SKILL.md.)
```

- [ ] **Step 3: Verify focus sidecar content matches and doc is clean**

Run:
```bash
grep -c 'design-level soundness' skills/brainstorming/adversarial-spec-review-focus.md
grep -nE 'CODEX_COMPANION|mktemp|node "\$CODEX_COMPANION"' skills/brainstorming/adversarial-spec-review-prompt.md && echo "LEFTOVER" || echo "CLEAN"
```
Expected: `1`, then `CLEAN`.

- [ ] **Step 4: Commit**

```bash
git add skills/brainstorming/adversarial-spec-review-focus.md skills/brainstorming/adversarial-spec-review-prompt.md
git commit -m "refactor(brainstorming): extract adversarial focus to sidecar"
```

---

### Task 10: `final-code-reviewer` → focus sidecar + doc

**Files:**
- Create: `skills/subagent-driven-development/final-code-reviewer-focus.md`
- Modify: `skills/subagent-driven-development/final-code-reviewer-prompt.md`

- [ ] **Step 1: Write the focus sidecar** (`final-code-reviewer-focus.md`) — exact focus text, no framing:

```
Focus: challenge cross-task integration seams — types, interfaces, naming conventions, and shared state that must be consistent across task boundaries; drift from the plan's overall intent (requirements that fell through the cracks between tasks, scaffolding or TODOs left behind, dead code from the task-by-task process); and the ship/no-ship merge judgment for the implementation as a whole. Adversarially probe: auth/permissions/isolation correctness across the full change set, data-loss or corruption risks introduced by the combined changes, rollback and partial-failure behavior end-to-end, race conditions and ordering assumptions that span multiple tasks, missing observability (logging/metrics/tracing) for the integrated feature.
```

- [ ] **Step 2: Replace the prompt doc** (`final-code-reviewer-prompt.md`) with human-facing notes only:

```markdown
# Final Code Reviewer — `dispatch.sh adversarial`

Reviewer 7. Run once, after every task has passed both its spec compliance and code
quality reviews. Dispatched via
`dispatch.sh adversarial --base <IMPL_BASE> --focus <…>/final-code-reviewer-focus.md`
(codex companion `adversarial-review`; focus text is the trailing positional, `--wait` is
boolean). The focus text lives in `final-code-reviewer-focus.md`.

**Purpose:** Challenge the entire implementation as a coherent whole — cross-task
integration seams, drift from the plan's overall intent, and ship/no-ship judgment.

`IMPL_BASE` is the `git rev-parse HEAD` captured before the very first implementer started
this plan; it must be a direct ancestor of HEAD. `--base` makes the companion diff
`git diff $(git merge-base HEAD <IMPL_BASE>)..HEAD`, covering the entire implementation.

## Verdict parsing

- `Verdict: approve` → passes the final gate; proceed to `superpowers:finishing-a-development-branch`.
- `Verdict: needs-attention` → collect every finding (file, line range, recommendation),
  dispatch the implementer to fix all, then re-run from the start with the same
  `IMPL_BASE`. Repeat until `Verdict: approve`.

**Zero tolerance; do not ask the user** — the loop runs automatically until the gate clears.

(The exact dispatch invocation lives in the subagent-driven-development SKILL.md.)
```

- [ ] **Step 3: Verify**

Run:
```bash
grep -c 'cross-task integration seams' skills/subagent-driven-development/final-code-reviewer-focus.md
grep -nE 'CODEX_COMPANION|mktemp|node "\$CODEX_COMPANION"' skills/subagent-driven-development/final-code-reviewer-prompt.md && echo "LEFTOVER" || echo "CLEAN"
```
Expected: `1`, then `CLEAN`.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/final-code-reviewer-focus.md skills/subagent-driven-development/final-code-reviewer-prompt.md
git commit -m "refactor(sdd): extract final-code-reviewer focus to sidecar"
```

---

### Task 11: Update `writing-plans/SKILL.md` to dispatch via `dispatch.sh`

**Files:**
- Modify: `skills/writing-plans/SKILL.md`

The SKILL.md currently instructs dispatching the per-Task reviewer and Coverage Verifier "using the template in `./plan-document-reviewer-prompt.md`" / "`./coverage-verifier-prompt.md`" with the embedded bash. Replace those dispatch mechanics with `dispatch.sh` invocations. **Read the current file before editing** and replace the dispatch descriptions in the "Per-Task Review", "Coverage Verifier", and "The Round Loop" subsections.

- [ ] **Step 1: Add a "Dispatch mechanism" subsection** just before "### Per-Task Review". Insert this exact content (the `${CLAUDE_PLUGIN_ROOT}` tokens are inline-expanded when the SKILL loads; in a non-plugin install they are not, so the guard's `-x` test fails and stops with a clear message):

````markdown
### Dispatch mechanism (shared `dispatch.sh`)

All reviewers go through the plugin's shared script, **run from the repository root**.
`${CLAUDE_PLUGIN_ROOT}` is inline-expanded inside this SKILL.md at load time, so the paths
below become absolute plugin-cache paths; plan/spec paths stay repo-root-relative.

Each reviewer is a **separate** `run_in_background: true` Bash call (its own shell), so each
block below is self-contained: it re-establishes the guard before invoking dispatch.

Per-Task reviewer — one per active Task:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
"$DISPATCH" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/plan-document-reviewer-prompt.md" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --set TASK_ID="Task N"
```

Coverage Verifier — once per round while active:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
"$DISPATCH" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/coverage-verifier-prompt.md" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md
```
````

- [ ] **Step 2: Remove the stale paste-based dispatch prose** in the existing "### Per-Task Review", "### Coverage Verifier", and "### The Round Loop" subsections, and point them at the invocations from Step 1. Make these exact edits:
  - In **### Per-Task Review**: delete the sentence "Each reviewer call receives the full text of the single Task under review plus the full text of all sibling Tasks as context." and replace it with: "Each reviewer call passes `--set TASK_ID=\"Task N\"`; the reviewer reads the plan file, locates that Task, and treats every other Task in the file as sibling context — no Task text is pasted." Replace the phrase "dispatch a per-Task reviewer using the template in `./plan-document-reviewer-prompt.md`" with "dispatch a per-Task reviewer using the Per-Task invocation in **Dispatch mechanism** above".
  - In **### Coverage Verifier**: replace "using the template in `./coverage-verifier-prompt.md`" with "using the Coverage Verifier invocation in **Dispatch mechanism** above".
  - In **### The Round Loop**: the `run_in_background`/parallel behavior is unchanged; only replace any remaining wording that implies pasting templates with a pointer to the **Dispatch mechanism** invocations.
  - In the **"Plan Review Loop"** intro / reviewer-role bullets: replace every statement that a reviewer is "dispatched via `node <companion> task`" (or similar embedded-companion wording) with "dispatched via `dispatch.sh` (see **Dispatch mechanism**)".
  - In **"Unified Re-run Policy" principle 2**: replace "the reviewer is given the full text of all sibling Tasks as context" with "the reviewer reads the plan file and treats all other Tasks as sibling context (no Task text is pasted)".

- [ ] **Step 3: Verify dispatch.sh is referenced and no stale dispatch mechanics / paste prose remain**

Run:

```bash
F=skills/writing-plans/SKILL.md
grep -c 'dispatch.sh' "$F"   # expect >= 1
grep -nE 'CODEX_COMPANION|<<.?PROMPT|mktemp|node <companion>|task --prompt-file|using the template|invocation blocks.*canonical|full text of (the single|all sibling)' "$F" && echo "LEFTOVER" || echo "CLEAN"
```

Expected: non-zero `dispatch.sh` count; `CLEAN` (no stale bash, no embedded-companion dispatch, no paste-based prose anywhere in the file — including the "Plan Review Loop" intro and "Unified Re-run Policy"). The `--prompt` paths legitimately name the `*-prompt.md` files, so the grep deliberately targets only the stale *phrasing*, not those filenames.

- [ ] **Step 4: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "refactor(writing-plans): dispatch reviewers via shared dispatch.sh"
```

---

### Task 12: Update `brainstorming/SKILL.md` to dispatch via `dispatch.sh`

**Files:**
- Modify: `skills/brainstorming/SKILL.md`

Replace the dual-reviewer dispatch mechanics (Reviewer 1 `task`, Reviewer 2 `adversarial-review`) with `dispatch.sh`. **Read the current file before editing.**

- [ ] **Step 1: Replace the dispatch wording** in the "Spec Review Loop (Dual Reviewer, codex companion)" section with the content below, and **delete any stale sentences** there that (a) say a reviewer "uses `spec-document-reviewer-prompt.md`/`adversarial-spec-review-prompt.md`" as a dispatch template, or (b) say "the invocation blocks in the prompt templates are canonical", or (c) embed `node <companion> …` / heredoc dispatch. Reviewer 1 reads its prompt sidecar; Reviewer 2 uses the **focus** sidecar.

````markdown
**Dispatch mechanism (shared `dispatch.sh`, run from repo root).** `${CLAUDE_PLUGIN_ROOT}`
is inline-expanded inside this SKILL.md at load time; the spec path is repo-root-relative.

Each reviewer is a **separate** `run_in_background: true` Bash call (its own shell), so each
block re-establishes the guard before invoking dispatch.

Reviewer 1 — Structural Completeness:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
"$DISPATCH" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/brainstorming/spec-document-reviewer-prompt.md" \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md
```

Reviewer 2 — Design Soundness:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
SPEC_BASE="<captured SPEC_BASE SHA>"   # own shell: rebind to the concrete SHA captured before the spec commit
"$DISPATCH" adversarial \
  --base "$SPEC_BASE" \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/brainstorming/adversarial-spec-review-focus.md"
```
````

- [ ] **Step 2: Verify dispatch.sh wired and stale dispatch mechanics gone**

Run:

```bash
F=skills/brainstorming/SKILL.md
grep -c 'dispatch.sh' "$F"   # expect >= 1
grep -nE 'CODEX_COMPANION|<<.?PROMPT|mktemp|node "?\$?CODEX|node <companion>|task --prompt-file|prompt templates are canonical|invocation block|adversarial-spec-review-prompt\.md' "$F" && echo "LEFTOVER" || echo "CLEAN"
```

Expected: non-zero `dispatch.sh` count; `CLEAN`. (The `--prompt`/`--focus` paths legitimately name the sidecar files; the grep targets only stale dispatch *mechanics/phrasing*.)

- [ ] **Step 3: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "refactor(brainstorming): dispatch dual spec reviewers via dispatch.sh"
```

---

### Task 13: Update `subagent-driven-development/SKILL.md` (dispatch + `--report-file` step)

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`

Replace the dispatch mechanics for reviewers 5/6/7 and add the report-file step for the spec compliance reviewer. **Read the current file before editing.**

- [ ] **Step 0: Delete the stale dispatch content.** Before inserting the new blocks, remove/rewrite every part of the SKILL that still teaches the old codex-prompt-template dispatch, so nothing contradicts `dispatch.sh`:
  - The **"Reviewer Dispatch Mechanisms"** section and any reviewer **table** rows that map reviewers 5/6/7 to `codex task` / `codex review` / `codex adversarial-review` prompt templates.
  - The **"Prompt Templates"** list entries and any prose that says "see the prompt templates for full dispatch commands" or "the invocation blocks are canonical".
  - **Workflow diagram labels** and **example workflow** text that reference `task --prompt-file` / `node <companion>` dispatch.
  - Note the new reality: reviewer 6 (`code-quality-reviewer-prompt.md`) and reviewer 7 (`final-code-reviewer-prompt.md`) are **human-facing support docs** (Tasks 8/10) — reference them as docs, never as dispatch templates; reviewer 7 dispatch uses `final-code-reviewer-focus.md`.
  - **Replacement terminology when rewriting the table / diagram / example workflow** (use exactly these so the file is internally consistent): reviewer 5 = "`dispatch.sh task` with `--report-file` (spec-reviewer sidecar)"; reviewer 6 = "`dispatch.sh review` (native review, no prompt sidecar)"; reviewer 7 = "`dispatch.sh adversarial` with `final-code-reviewer-focus.md`". Do not leave any "via codex task" / "codex native review" / "codex adversarial-review" / "prompt templates" dispatch phrasing.

- [ ] **Step 1: Add the spec-compliance dispatch with the report-file step.** Where the SKILL describes dispatching reviewer 5 (spec compliance), insert:

````markdown
**Dispatch mechanism (shared `dispatch.sh`, run from repo root).** Each reviewer is a
separate `run_in_background: true` Bash call (its own shell); every dispatch block below is
self-contained and re-establishes the guard.

Spec compliance reviewer (reviewer 5). Procedure:

1. Run `REPORT_FILE="$(mktemp)"; echo "$REPORT_FILE"` and **note the concrete printed path**
   (one per reviewer — never reuse or share a path across concurrent reviewers).
2. **Write the implementer subagent's returned report verbatim into that concrete path using
   the Write tool** (do not paste the report into the dispatch command).
3. Dispatch. This block runs in its **own** background shell, so it re-binds `REPORT_FILE`
   and `TASK_BASE` to the concrete values from earlier (the mktemp path from step 1 and the
   captured task base SHA) — substitute them in the two marked lines:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
REPORT_FILE="/abs/path/from/step/1"        # <- concrete mktemp path noted in step 1
TASK_BASE="<captured task base SHA>"       # <- concrete SHA captured before the implementer
"$DISPATCH" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/spec-reviewer-prompt.md" \
  --report-file "$REPORT_FILE" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set TASK_ID="Task N" \
  --set TASK_BASE="$TASK_BASE"
```

4. After this background dispatch's **completion notification**, delete the source file:
   `rm -f "$REPORT_FILE"` (using the same concrete path).

`dispatch.sh` copies the report into its own private temp and injects that private path, so
reviewer correctness does not depend on when step 4 runs.
````

- [ ] **Step 2: Replace reviewer 6 (code quality) dispatch** with (self-contained guard + call):

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
TASK_BASE="<captured task base SHA>"   # own shell: rebind to the concrete SHA captured before this task's implementer
"$DISPATCH" review --base "$TASK_BASE"
```

- [ ] **Step 3: Replace reviewer 7 (final) dispatch** with (self-contained guard + call):

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"; DISPATCH="$PLUGIN_ROOT/scripts/dispatch.sh"
# Non-plugin/shadowed install: the plugin-root token did not inline-expand, so PLUGIN_ROOT is
# empty (bash expanded the unset env var) or still holds the literal token. Reject both.
# NOTE: the pattern uses the BARE word (no ${...}) so Claude Code's inline expansion does not
# rewrite it — a real expanded cache path never contains the substring "CLAUDE_PLUGIN_ROOT".
case "$PLUGIN_ROOT" in ''|*CLAUDE_PLUGIN_ROOT*) echo "superpowers-codex must be installed as a plugin (run /plugin install); reviewer dispatch is unavailable (plugin root did not expand)." >&2; exit 1 ;; esac
[ -x "$DISPATCH" ] || { echo "superpowers-codex dispatch.sh is missing or not executable; reinstall the plugin (/plugin install)." >&2; exit 1; }
IMPL_BASE="<captured IMPL_BASE SHA>"   # own shell: rebind to the concrete SHA captured before the first implementer
"$DISPATCH" adversarial \
  --base "$IMPL_BASE" \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/final-code-reviewer-focus.md"
```

- [ ] **Step 4: Verify**

Run:

```bash
F=skills/subagent-driven-development/SKILL.md
grep -c 'dispatch.sh' "$F"            # expect >= 1
grep -c -- '--report-file' "$F"       # expect >= 1
grep -nE 'CODEX_COMPANION|<<.?PROMPT|node <companion>|task --prompt-file|Reviewer Dispatch Mechanisms|via codex |codex native review|codex adversarial-review|prompt templates are canonical|See the prompt templates' "$F" && echo "LEFTOVER" || echo "CLEAN"
```

Expected: non-zero `dispatch.sh` count; `--report-file` count ≥ 1; `CLEAN`. (Note: `implementer-prompt.md` still uses its own heredoc — that file is NOT edited; the grep targets SKILL.md only. The grep deliberately targets stale dispatch *mechanics/phrasing*, not the bare `code-quality-reviewer-prompt.md` / `final-code-reviewer-prompt.md` names, which may legitimately remain as human-facing support-doc references.)

- [ ] **Step 5: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "refactor(sdd): dispatch reviewers via dispatch.sh, pass report by file"
```

---

### Task 14: Rewrite README distribution + install/migration sections

**Files:**
- Modify: `README.md`

**Read the current README before editing.** Update the "Distribution form" note and add install + migration sections. (The vendor maintenance model sections stay as-is — manifests and `scripts/` are main-only.)

- [ ] **Step 1: Replace the distribution-form blockquote** near the top with:

```markdown
> Distribution form: a Claude Code **plugin** (with `.claude-plugin/plugin.json` and a
> `.claude-plugin/marketplace.json`). Skills under `skills/<name>/` are auto-discovered;
> reviewers are dispatched through the bundled `scripts/dispatch.sh` via
> `${CLAUDE_PLUGIN_ROOT}`.
```

- [ ] **Step 2: Add an "Install" section.** The two commands are **Claude Code slash commands**, not shell — put them in a plain (unlabeled) fence and say so, so users don't paste them into a terminal:

````markdown
## Install

Run these inside Claude Code (they are slash commands, not shell commands):

```
/plugin marketplace add stu43005/superpowers-codex
/plugin install superpowers-codex
```
````

- [ ] **Step 3: Add a "Migrating from a skills-collection install" section:**

````markdown
## Migrating from a skills-collection install

Earlier versions were dropped into `~/.claude/skills/`. A leftover copy can **shadow** the
plugin, so its `SKILL.md` (and the dispatch guard inside it) would never load. Claude Code
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
any bundled skill once** and let it reach a reviewer dispatch. The dispatch guard aborts with
"must be installed as a plugin" **iff** the token did not expand, so the skill reaching its
dispatch **without that guard error** confirms expansion. (Do not try to read a `dispatch.sh`
path out of `--dry-run` output — that output is the `node <companion> …` command, and
`<companion-unresolved>` means codex is not set up, not that a legacy copy shadows the plugin.)

Migration is complete once the preflight passes, the cache-present / no-legacy checks pass,
and a bundled skill reaches a reviewer dispatch without the plugin guard error.
````

- [ ] **Step 4: Verify**

Run: `grep -c 'plugin install\|preflight-plugin-install' README.md`
Expected: non-zero.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document plugin distribution, install, and migration"
```

---

### Task 15: Verification & smoke tests (operational)

**Files:**
- Modify (append results): `README.md` (record the empirically-determined discovery precedence)

This task runs the spec §8 checks plus the runtime-only determinations the spec defers
(discovery precedence). **No `plugin.json` hook is added**: Claude Code has no install-time
hook (verified), so the preflight is manual (Task 14) — this task only confirms that.

- [ ] **Step 1: Static + unit checks (re-run aggregate)**

Run:
```bash
bash -n scripts/dispatch.sh && bash -n scripts/preflight-plugin-install.sh
if command -v shellcheck >/dev/null; then shellcheck scripts/dispatch.sh scripts/preflight-plugin-install.sh; else echo "shellcheck not installed; relying on bash -n + test runners"; fi
bash scripts/dispatch.test.sh
bash scripts/preflight.test.sh
```
Expected: both test runners report `0 failed` (exit 0).

- [ ] **Step 2: `--dry-run` matrix for every reviewer invocation (repo-local)**

`${CLAUDE_PLUGIN_ROOT}` is NOT set in a plain shell, so test against the repo copy with
`bash scripts/dispatch.sh` and repo-relative paths (run from repo root):

```bash
PLAN=docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md
SPEC=docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md
bash scripts/dispatch.sh task --prompt skills/writing-plans/plan-document-reviewer-prompt.md \
  --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --set TASK_ID="Task 2" --dry-run
bash scripts/dispatch.sh task --prompt skills/writing-plans/coverage-verifier-prompt.md \
  --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --dry-run
bash scripts/dispatch.sh task --prompt skills/brainstorming/spec-document-reviewer-prompt.md \
  --set SPEC_FILE_PATH="$SPEC" --dry-run
RF="$(mktemp)"; printf 'report\n' > "$RF"
bash scripts/dispatch.sh task --prompt skills/subagent-driven-development/spec-reviewer-prompt.md \
  --report-file "$RF" --set PLAN_FILE_PATH="$PLAN" --set TASK_ID="Task 2" --set TASK_BASE=HEAD --dry-run; rm -f "$RF"
bash scripts/dispatch.sh review --base HEAD --dry-run
bash scripts/dispatch.sh adversarial --base HEAD --focus skills/brainstorming/adversarial-spec-review-focus.md --dry-run
bash scripts/dispatch.sh adversarial --base HEAD --focus skills/subagent-driven-development/final-code-reviewer-focus.md --dry-run
```

Expected: every call exits 0; each `task` prints a placeholder-free prompt (no `[UPPER_CASE]`
token) plus the `node … --prompt-file …` command; `review`/`adversarial` print their `node …`
commands. (The installed codex 1.0.4 satisfies the version guard.)

- [ ] **Step 3: Companion version guard (executable, via `DISPATCH_COMPANION`)**

```bash
PLAN=docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md
SPEC=docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md
OLD=/tmp/fakecodex/codex/0.9.0/scripts/codex-companion.mjs; mkdir -p "$(dirname "$OLD")"; : > "$OLD"
FB=/tmp/fakecodex/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs; mkdir -p "$(dirname "$FB")"; : > "$FB"
DISPATCH_COMPANION="$OLD" bash scripts/dispatch.sh task --prompt skills/writing-plans/coverage-verifier-prompt.md --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --dry-run; echo "old rc=$?"
DISPATCH_COMPANION="$FB"  bash scripts/dispatch.sh review --base HEAD --dry-run 2>&1; echo "fallback rc=$?"
rm -rf /tmp/fakecodex
```

Expected: `old rc` non-zero (a versioned cache path below the minimum) citing `< required 1.0.4`
and `/codex:setup`. `fallback rc` **also non-zero** — a fallback path has no version segment, so
the guard `die`s with "cannot determine codex companion version … run /codex:setup" (an
unverifiable companion is never run; the user installs a versioned cache copy via /codex:setup).

- [ ] **Step 4: §8 robustness — path validation, isolation, interrupt cleanup, foreground sync**

```bash
PLAN=docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md
SPEC=docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md
ROOT="$(pwd)"; T="${TMPDIR:-/tmp}"; CV=skills/writing-plans/coverage-verifier-prompt.md
# (a) wrong cwd: absolute --prompt (exists) but repo-relative --set fails loudly on the --set path
( cd /tmp && bash "$ROOT/scripts/dispatch.sh" task --prompt "$ROOT/$CV" \
    --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --dry-run ); echo "wrong-cwd rc=$?"   # expect non-zero
# (b) metachar incl. backslash substituted literally (TASK_ID is not a *_FILE_PATH key)
bash scripts/dispatch.sh task --prompt skills/writing-plans/plan-document-reviewer-prompt.md \
  --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --set 'TASK_ID=T \ & # [x]' --dry-run | grep -F 'T \ & # [x]'   # expect a match
# (c) normal-exit cleanup: a successful dry-run leaves no new private temp
b=$(ls "$T"/dispatch.* 2>/dev/null | wc -l)
bash scripts/dispatch.sh task --prompt "$CV" --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --dry-run >/dev/null
a=$(ls "$T"/dispatch.* 2>/dev/null | wc -l); [ "$a" -le "$b" ] && echo "normal-exit cleanup OK" || echo "FAIL: leak (normal)"
# (d) validation-failure cleanup: a failing run (bad --set path) also leaves no new private temp
b=$(ls "$T"/dispatch.* 2>/dev/null | wc -l)
bash scripts/dispatch.sh task --prompt "$CV" --set PLAN_FILE_PATH=/no/such --set SPEC_FILE_PATH="$SPEC" --dry-run >/dev/null 2>&1 || true
a=$(ls "$T"/dispatch.* 2>/dev/null | wc -l); [ "$a" -le "$b" ] && echo "validation-failure cleanup OK" || echo "FAIL: leak (validation)"
# (e) parallel isolation: two concurrent dispatches inject DISTINCT private report copies
R1="$(mktemp)"; printf 'R1\n' >"$R1"; R2="$(mktemp)"; printf 'R2\n' >"$R2"; PR="$T/withrep.$$.md"; printf 'R: [REPORT_FILE_PATH]\n' >"$PR"
bash scripts/dispatch.sh task --prompt "$PR" --report-file "$R1" --dry-run >"$T/o1.$$" 2>&1 &
bash scripts/dispatch.sh task --prompt "$PR" --report-file "$R2" --dry-run >"$T/o2.$$" 2>&1 &
wait
# the REPORT private-copy path is on the injected "R: " line specifically (not the work-prompt
# path in the printed node command), so extract from that line:
p1=$(grep '^R: ' "$T/o1.$$" | grep -o 'dispatch\.[A-Za-z0-9]*' | head -1); p2=$(grep '^R: ' "$T/o2.$$" | grep -o 'dispatch\.[A-Za-z0-9]*' | head -1)
{ [ -n "$p1" ] && [ -n "$p2" ] && [ "$p1" != "$p2" ]; } && echo "parallel isolation OK" || echo "FAIL: report copies not distinct"
rm -f "$R1" "$R2" "$PR" "$T/o1.$$" "$T/o2.$$"
# (f) interrupt cleanup (dynamic + portable): start a dispatch whose companion sleeps, then
# kill the foreground node child with pkill (mimics the foreground job being signalled on a
# Ctrl-C). dispatch.sh's foreground call returns and its trap cleans the private temp. Killing
# the child (not the single bash PID) sidesteps bash's deferred-trap behaviour and needs no
# setsid, so it is portable to macOS. Also assert the trap covers INT/TERM.
SLEEP=/tmp/fakecodex/codex/9.9.9/scripts/codex-companion.mjs; mkdir -p "$(dirname "$SLEEP")"; printf 'setTimeout(()=>{},300000);\n' >"$SLEEP"
before=$(ls "$T"/dispatch.* 2>/dev/null | wc -l)
DISPATCH_COMPANION="$SLEEP" bash scripts/dispatch.sh task --prompt "$CV" --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" & DPID=$!
sleep 1; pkill -TERM -P "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
after=$(ls "$T"/dispatch.* 2>/dev/null | wc -l); rm -rf /tmp/fakecodex
grep -Eq 'trap[[:space:]]+cleanup[[:space:]]+EXIT[[:space:]]+INT[[:space:]]+TERM' scripts/dispatch.sh && trapok=1 || trapok=0
{ [ "$after" -le "$before" ] && [ "$trapok" = 1 ]; } && echo "interrupt cleanup OK" || echo "FAIL: leak after interrupt, or trap missing"
# (g) external --set file inputs are NEVER deleted by dispatch.sh (only its own mktemp files are)
bash scripts/dispatch.sh task --prompt "$CV" --set PLAN_FILE_PATH="$PLAN" --set SPEC_FILE_PATH="$SPEC" --dry-run >/dev/null
{ [ -f "$PLAN" ] && [ -f "$SPEC" ]; } && echo "external --set inputs preserved OK" || echo "FAIL: dispatch deleted an external input"
```

Expected: (a) non-zero; (b) prints a matching line; (c) `normal-exit cleanup OK`;
(d) `validation-failure cleanup OK`; (e) `parallel isolation OK`; (f) `interrupt cleanup OK`;
(g) `external --set inputs preserved OK`.
Additionally — **live foreground sync (needs the real codex companion installed)**: confirm
a real `task` dispatch (no `--dry-run`) blocks until the full reviewer output — including the
final `Status:` line — is printed, then returns:

```bash
PLAN=docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md
RF="$(mktemp)"; printf 'implementer report (smoke)\n' > "$RF"
bash scripts/dispatch.sh task \
  --prompt skills/subagent-driven-development/spec-reviewer-prompt.md \
  --report-file "$RF" \
  --set PLAN_FILE_PATH="$PLAN" --set TASK_ID="Task 2" --set TASK_BASE="$(git rev-parse HEAD)"
echo "returned rc=$?"; rm -f "$RF"
```

Expect the command to print the reviewer's full output ending in a `Status:` line and only
then print `returned rc=…` — it must not return early or background. Parallel private-copy
isolation is already covered by `dispatch.test.sh`.

- [ ] **Step 5: Confirm no install hook + plugin install smoke test (do before Step 6)**

Confirm (already verified against docs) that `/plugin install` does NOT run the preflight —
no `plugin.json` hook exists or is added; the README mandates the manual preflight.

**Install THIS checkout, not a stale remote.** To exercise the files built by Tasks 1-14,
add this repo as a **local** marketplace (Claude Code accepts a local marketplace path); if
your setup requires a remote, push the branch first and use `stu43005/superpowers-codex`. Run
in Claude Code (slash commands, not shell):

```
/plugin marketplace add /Users/stu43005/Sources/superpowers-codex
/plugin install superpowers-codex
```

Then run these two deterministic checks (shell — if either fails, the smoke test is invalid):

```bash
# (1) the installed cache holds THIS branch's dispatch.sh, and it is executable
CACHE_DS="$(ls -d ~/.claude/plugins/cache/*/superpowers-codex/*/scripts/dispatch.sh 2>/dev/null | sort | tail -1)"
[ -n "$CACHE_DS" ] && [ -x "$CACHE_DS" ] || echo "FAIL: plugin dispatch.sh not found/executable in cache"
grep -q 'mk_private' "$CACHE_DS" && grep -q 'DISPATCH_COMPANION' "$CACHE_DS" \
  && echo "OK: installed dispatch.sh matches this branch" || echo "FAIL: cache holds stale dispatch.sh"
# (2) the CACHED dispatch.sh actually runs a reviewer dispatch (proves the installed copy works)
CACHE_ROOT="${CACHE_DS%/scripts/dispatch.sh}"
bash "$CACHE_DS" task --prompt "$CACHE_ROOT/skills/writing-plans/coverage-verifier-prompt.md" \
  --set PLAN_FILE_PATH="docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md" \
  --set SPEC_FILE_PATH="docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md" --dry-run >/dev/null \
  && echo "OK: cached dispatch.sh executes a reviewer dispatch" || echo "FAIL: cached dispatch.sh did not run"
```

Expect both `OK`. Finally, confirm **inline `${CLAUDE_PLUGIN_ROOT}` expansion at skill-load time**
with a concrete, deterministic observation (no need to drive a full workflow to a live
dispatch): invoke the **namespaced** `superpowers-codex:writing-plans` and read the loaded
skill text shown in context — its **Dispatch mechanism** block must show an **absolute**
`…/plugins/cache/…/scripts/dispatch.sh` path (expansion worked), not a literal
`${CLAUDE_PLUGIN_ROOT}`. (Do not look for a `dispatch.sh` path in `--dry-run` *output* — that
output is the `node <companion> …` command; the load-time check is the inline-expanded path in
the SKILL text itself.)

- [ ] **Step 6: Discovery-precedence empirical determination (operational; not in docs)**

The plugin is now installed (Step 5). Skill precedence between a plugin skill and a plain
legacy copy is undocumented, so measure it on the running Claude Code for **both** legacy
locations. Record the Claude Code version (`claude --version`).

> **SAFETY (Steps 6–7 touch real `~/.claude/skills` / `~/.agents/skills`).** The precedence
> test needs the real Claude home (that is where Claude Code loads skills from), so a sandbox
> `HOME` will not work. **Back up any real user copies first and restore them at the end of
> Step 7.** Never `rm -rf` a path you did not create here.

```bash
# SAFETY: move ANY real user copy of EVERY skill the preflight scans (4 names x 2 locations)
# into a fresh backup dir — not just writing-plans — so Step 7's "clean rc=0" reflects a truly
# clean state. Handles regular dirs and symlinks; aborts rather than clobber a prior backup.
BK=/tmp/sp-fixture-backup
[ -e "$BK" ] && { echo "backup dir $BK exists; resolve it before running these fixtures" >&2; exit 1; }
mkdir -p "$BK"; i=0
for base in ~/.claude/skills ~/.agents/skills; do
  for s in brainstorming writing-plans subagent-driven-development finishing-a-development-branch; do
    d="$base/$s"
    if [ -e "$d" ] || [ -L "$d" ]; then printf '%s\n' "$d" > "$BK/item$i.path"; mv "$d" "$BK/item$i"; fi
    i=$((i+1))
  done
done
# Sentinel legacy copy with a unique marker in the body:
mkdir -p ~/.claude/skills/writing-plans
printf '%s\n' '---' 'name: writing-plans' 'description: LEGACY-SENTINEL-XYZZY' '---' 'LEGACY-SENTINEL-XYZZY' > ~/.claude/skills/writing-plans/SKILL.md
```

Concrete observation: invoke the bare skill (Skill tool with `skill: writing-plans`, or
`/writing-plans`) and inspect the **loaded skill text** shown in context:
- contains `LEGACY-SENTINEL-XYZZY` → legacy wins;
- contains the plugin's real heading ("Writing Plans") → plugin wins;
- the bare name is unavailable and only `superpowers-codex:writing-plans` resolves →
  namespaced-no-collision.

Then remove the first fixture and set up the second location with the same explicit commands,
and observe again (the two locations may differ):

```bash
rm -rf ~/.claude/skills/writing-plans
mkdir -p ~/.agents/skills/writing-plans
printf '%s\n' '---' 'name: writing-plans' 'description: LEGACY-SENTINEL-XYZZY' '---' 'LEGACY-SENTINEL-XYZZY' > ~/.agents/skills/writing-plans/SKILL.md
```

Invoke the bare skill again and classify the same way. Record **both** outcomes in README's
migration section using this exact block:

```markdown
### Skill discovery precedence (measured)

On Claude Code <version from `claude --version`>, when a plugin skill and a plain legacy copy
of the same name coexist, the bare `/<name>` invocation loads:
- legacy at `~/.claude/skills/<name>`: **<plugin-wins | legacy-wins | namespaced-no-collision>**
- legacy at `~/.agents/skills/<name>`: **<plugin-wins | legacy-wins | namespaced-no-collision>**

Therefore legacy copies in both locations MUST be removed before relying on the plugin.
```

Then clean up: `rm -rf ~/.claude/skills/writing-plans ~/.agents/skills/writing-plans`.

- [ ] **Step 7: Migration shadow smoke test**

Recreate a legacy copy (Step 6 removed it), then verify the preflight blocks it:

```bash
mkdir -p ~/.claude/skills/writing-plans; : > ~/.claude/skills/writing-plans/SKILL.md
PF="$(ls -d ~/.claude/plugins/cache/*/superpowers-codex/*/scripts/preflight-plugin-install.sh | sort | tail -1)"
"$PF"; echo "shadow rc=$?"        # expect non-zero, naming ~/.claude/skills/writing-plans
rm -rf ~/.claude/skills/writing-plans
"$PF"; echo "clean rc=$?"         # expect 0
# SAFETY: restore anything moved into the Step 6 backup dir, then remove the backup dir.
BK=/tmp/sp-fixture-backup
for p in "$BK"/item*.path; do
  [ -e "$p" ] || continue
  d="$(cat "$p")"; rm -rf "$d"; mv "${p%.path}" "$d"
done
rm -rf "$BK"
```

Confirm the first run exits non-zero naming the path and the second exits 0. (Reviewer
dispatch through the installed plugin is proven by Step 5's cached-`dispatch.sh` dry-run and
the inline-expansion observation — not repeated here.)

- [ ] **Step 8: Commit any recorded results**

```bash
git add README.md
git commit -m "docs: record empirically-determined skill discovery precedence"
```

---

## Done criteria

- `scripts/dispatch.test.sh` and `scripts/preflight.test.sh` pass (0 failed).
- `bash -n` (and `shellcheck` where available) clean on both scripts.
- Every reviewer `--dry-run` produces a placeholder-free prompt and a correct companion command.
- The seven prompt files are slimmed/converted; the two focus sidecars exist; the three SKILL.md files dispatch via `dispatch.sh`; `implementer-prompt.md` is untouched.
- Plugin installs; `${CLAUDE_PLUGIN_ROOT}` inline-expands inside SKILL.md; the preflight blocks a shadowing legacy install; README documents install + migration with the recorded discovery-precedence result.
