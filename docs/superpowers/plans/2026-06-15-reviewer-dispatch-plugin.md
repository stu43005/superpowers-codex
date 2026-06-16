# Reviewer Dispatch Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package this skills collection as a Claude Code plugin with one shared `scripts/dispatch.sh`, slim the seven reviewer prompt files into pure sidecar bodies, and switch every reviewer to passing paths/identifiers so each reviewer reads its own inputs (no pasted bulk text), with an enforceable migration guard.

**Architecture:** A plugin manifest (`.claude-plugin/`) makes `${CLAUDE_PLUGIN_ROOT}` available for inline expansion inside SKILL.md content. A single `scripts/dispatch.sh` (subcommands `task`/`review`/`adversarial`) centralizes codex-companion resolution, a path-derived version guard, data-safe placeholder substitution, path validation, and self-contained report-file lifetime. Reviewer `*-prompt.md` files become pure prompt bodies with `[PLACEHOLDER]` tokens; Type B focus strings move to `*-focus.md` sidecars. A standalone `scripts/preflight-plugin-install.sh` (which never sources a SKILL.md) blocks migration when a legacy skills-collection copy would shadow the plugin.

**Tech Stack:** Bash (POSIX-leaning, must pass on macOS/BSD and GNU/Linux), Node-based codex companion (`codex-companion.mjs`, pinned ≥ 1.0.4), Claude Code plugin/marketplace manifests, Markdown skill docs.

**Source spec:** [docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md](../specs/2026-06-15-reviewer-dispatch-plugin-design.md)

**Research findings already established (do not re-investigate; see spec §4.2 + Task 1):**
- The codex companion (`1.0.4`) has **no** version command. Its version is only the `/codex/<ver>/scripts/codex-companion.mjs` path segment → version guard extracts it from the resolved path.
- `task` is synchronous in the foreground unless `--background` is passed; `dispatch.sh` must never pass `--background`.
- `adversarial-review` takes the focus as **trailing positional** text; `--wait` is a boolean flag. `review` accepts `--base` + `--wait`. `task` accepts `--prompt-file`. There is no machine-readable capabilities listing (only `--help` usage text).

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

- [ ] **Step 1: Write `plugin.json`**

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

**Files:**
- Create: `scripts/dispatch.sh`
- Test: `scripts/dispatch.test.sh`

- [ ] **Step 1: Write the failing test runner**

Create `scripts/dispatch.test.sh`:

```bash
#!/usr/bin/env bash
# Plain-bash tests for dispatch.sh. No live codex: every case uses --dry-run
# or expects an early non-zero exit before any companion call.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/dispatch.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n   %s\n' "$1" "${2:-}"; }

# helper: run dispatch.sh, capture stdout+stderr and exit code
run() { OUT="$("$D" "$@" 2>&1)"; RC=$?; }

tmpprompt="$(mktemp)"; printf 'Plan: [PLAN_FILE_PATH]\nTask: [TASK_ID]\n' > "$tmpprompt"
tmpreport="$(mktemp)"; printf 'IMPLEMENTER REPORT BODY\n' > "$tmpreport"

# 1. data-safe substitution with metacharacters, via --dry-run
run task --prompt "$tmpprompt" --dry-run \
  --set PLAN_FILE_PATH='docs/a&b/c#1/[plan] x.md' --set TASK_ID='Task #3 & more'
case "$OUT" in
  *'docs/a&b/c#1/[plan] x.md'*) ok "metachar value substituted literally" ;;
  *) bad "metachar value substituted literally" "$OUT" ;;
esac
case "$OUT" in
  *'[PLAN_FILE_PATH]'*|*'[TASK_ID]'*) bad "no residual placeholder after subst" "$OUT" ;;
  *) ok "no residual placeholder after subst" ;;
esac

# 2. residual placeholder (missing --set) must fail non-zero
run task --prompt "$tmpprompt" --dry-run --set PLAN_FILE_PATH=x
[ "$RC" -ne 0 ] && ok "missing --set -> non-zero" || bad "missing --set -> non-zero" "rc=$RC"

# 3. newline in value rejected
run task --prompt "$tmpprompt" --dry-run --set PLAN_FILE_PATH=$'a\nb' --set TASK_ID=z
[ "$RC" -ne 0 ] && ok "newline value rejected" || bad "newline value rejected" "rc=$RC"

# 4. nonexistent --prompt fails
run task --prompt /no/such/file --dry-run
[ "$RC" -ne 0 ] && ok "missing prompt file -> non-zero" || bad "missing prompt file" "rc=$RC"

# 5. nonexistent --report-file fails
run task --prompt "$tmpprompt" --report-file /no/such/report --dry-run \
  --set PLAN_FILE_PATH=x --set TASK_ID=y
[ "$RC" -ne 0 ] && ok "missing report file -> non-zero" || bad "missing report file" "rc=$RC"

# 6. report content copied into a PRIVATE temp; dry-run prints that path and it differs from source
run task --prompt "$tmpprompt" --report-file "$tmpreport" --dry-run \
  --set PLAN_FILE_PATH=x --set TASK_ID=y
case "$OUT" in
  *"$tmpreport"*) bad "report private-copy path injected (not source)" "leaked source path" ;;
  *REPORT_FILE_PATH*) bad "report placeholder still present" "$OUT" ;;
  *) ok "report private-copy path injected (not source)" ;;
esac

# 7. source report file is NEVER deleted by dispatch.sh
[ -f "$tmpreport" ] && ok "source report file preserved" || bad "source report file preserved" "deleted"

# 8. unknown subcommand fails
run frobnicate --dry-run
[ "$RC" -ne 0 ] && ok "unknown subcommand -> non-zero" || bad "unknown subcommand" "rc=$RC"

# 9. review requires --base
run review --dry-run
[ "$RC" -ne 0 ] && ok "review without --base -> non-zero" || bad "review without --base" "rc=$RC"

# 10. dispatch.sh never backgrounds the companion (no '&' / --background)
grep -Eq '(&[[:space:]]*$|--background)' "$D" && bad "no background companion call" "found & or --background" || ok "no background companion call"

rm -f "$tmpprompt" "$tmpreport"
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
# Design: docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md
set -euo pipefail

# Pinned minimum codex companion version (calibrated to installed 1.0.4).
# The companion exposes NO version command; version is read from its install path.
MIN_COMPANION_VERSION="1.0.4"

err()  { printf '%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- cleanup: delete ONLY temp files this process created ---
_PRIVATE=()
cleanup() {
  local f
  for f in "${_PRIVATE[@]:-}"; do
    [ -n "${f:-}" ] && rm -f "$f"
  done
}
trap cleanup EXIT INT TERM
mk_private() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/dispatch.XXXXXX")"
  _PRIVATE+=("$f")
  printf '%s' "$f"
}

# --- companion resolution ---
resolve_companion() {
  local c
  c="$(ls -d "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -n1)"
  [ -n "$c" ] || c="$HOME/.claude/plugins/marketplaces/openai-codex/plugins/codex/scripts/codex-companion.mjs"
  [ -f "$c" ] || die "codex plugin not found; run /codex:setup. Do NOT fall back to inline self-review."
  printf '%s' "$c"
}

# --- version guard: read version from the .../codex/<ver>/scripts/... path segment ---
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
check_companion_version() {
  local companion="$1" ver=""
  case "$companion" in
    */codex/*/scripts/codex-companion.mjs)
      ver="${companion#*/codex/}"; ver="${ver%%/*}" ;;
  esac
  case "$ver" in
    [0-9]*.[0-9]*) ;;                       # looks like a version
    *) err "warning: cannot determine codex companion version from path; proceeding without version assertion"; return 0 ;;
  esac
  ver_ge "$ver" "$MIN_COMPANION_VERSION" || \
    die "codex companion $ver < required $MIN_COMPANION_VERSION; run /codex:setup to update codex."
}

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

  local work; work="$(mk_private)"
  cat "$prompt" > "$work"

  # report: copy source content into our OWN private file; inject the private path.
  if [ -n "$report_src" ]; then
    require_file "$report_src"
    local report_priv; report_priv="$(mk_private)"
    cat "$report_src" > "$report_priv"
    subst_into "$work" "REPORT_FILE_PATH" "$report_priv"
  fi

  local i
  for i in "${!set_keys[@]}"; do
    require_no_newline "${set_keys[$i]}" "${set_vals[$i]}"
    subst_into "$work" "${set_keys[$i]}" "${set_vals[$i]}"
  done
  assert_no_residual "$work"

  local companion; companion="$(resolve_companion)"
  check_companion_version "$companion"

  if [ "$dry" -eq 1 ]; then
    printf -- '--- DRY RUN: command ---\n'
    printf 'node %q task --prompt-file %q\n' "$companion" "$work"
    printf -- '--- DRY RUN: prompt ---\n'
    cat "$work"
    return 0
  fi
  # Foreground, blocking; NEVER --background (keeps temp files alive until reviewer done).
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
  local companion; companion="$(resolve_companion)"
  check_companion_version "$companion"
  if [ "$dry" -eq 1 ]; then
    printf 'node %q review --base %q --wait\n' "$companion" "$base"; return 0
  fi
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
  local companion; companion="$(resolve_companion)"
  check_companion_version "$companion"
  local focus_text; focus_text="$(cat "$focus")"
  if [ "$dry" -eq 1 ]; then
    # focus is a trailing POSITIONAL; --wait is a boolean flag.
    printf 'node %q adversarial-review --base %q --wait %q\n' "$companion" "$base" "$focus_text"; return 0
  fi
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

Run: `chmod +x scripts/dispatch.sh && bash -n scripts/dispatch.sh && shellcheck scripts/dispatch.sh`
Expected: no syntax errors; shellcheck clean (if `shellcheck` is unavailable, note it and rely on `bash -n` + the test runner).

- [ ] **Step 5: Run the test runner to verify it passes**

Run: `bash scripts/dispatch.test.sh`
Expected: `10 passed, 0 failed` (exit 0).

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

# 2. legacy shadow present -> non-zero, prints the offending path
mkdir -p "$SBOX/.claude/skills/writing-plans"
run
[ "$RC" -ne 0 ] && ok "legacy shadow fails" || bad "legacy shadow fails" "rc=$RC"
case "$OUT" in *writing-plans*) ok "names the offending path" ;; *) bad "names the offending path" "$OUT" ;; esac

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
# copy "wins" skill discovery. See spec §3.1.
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
    if [ -e "$p" ] || [ -L "$p" ]; then
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

Run: `chmod +x scripts/preflight-plugin-install.sh && bash -n scripts/preflight-plugin-install.sh && shellcheck scripts/preflight-plugin-install.sh && bash scripts/preflight.test.sh`
Expected: clean; `2 passed`/`3 passed` summary with `0 failed` (exit 0).

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
grep -nE 'CODEX_COMPANION|mktemp|<<.?PROMPT|How to Dispatch|--prompt-file' skills/writing-plans/plan-document-reviewer-prompt.md && echo "LEFTOVER" || echo "CLEAN"
grep -c '\[PLAN_FILE_PATH\]\|\[SPEC_FILE_PATH\]\|\[TASK_ID\]' skills/writing-plans/plan-document-reviewer-prompt.md
```
Expected: `CLEAN`, and a non-zero count for the placeholders.

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

- [ ] **Step 1: Add a "Dispatch mechanism" subsection** just before "### Per-Task Review" (or replace the existing per-template dispatch wording). Insert this content:

````markdown
### Dispatch mechanism (shared `dispatch.sh`)

All reviewers are dispatched through the plugin's shared script. **Run from the repository
root.** `dispatch.sh` and `--prompt` are plugin-bundled (absolute, via
`${CLAUDE_PLUGIN_ROOT}`); plan/spec paths are repo-root-relative.

**Pre-dispatch guard (non-plugin install):** If, after inline expansion, the path below
still contains the literal `${CLAUDE_PLUGIN_ROOT}`, or `dispatch.sh` is missing/not
executable, STOP — this skill requires plugin installation (`/plugin install`); do NOT
fall back to inline self-review.

Per-Task reviewer (one per active Task, `run_in_background: true`):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/plan-document-reviewer-prompt.md" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md \
  --set TASK_ID="Task N"
```

Coverage Verifier (once per round while active, `run_in_background: true`):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/coverage-verifier-prompt.md" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md
```
````

- [ ] **Step 2: Update the prose** in "### Per-Task Review" and "### Coverage Verifier" so they reference the dispatch invocations above instead of pasting Task text / sibling Tasks. The per-Task reviewer no longer receives pasted Task text — it reads the plan and locates `TASK_ID`; sibling context is the rest of the plan file. Remove any instruction to paste full Task text or sibling Tasks.

- [ ] **Step 3: Verify the SKILL no longer embeds dispatch bash and references dispatch.sh**

Run:
```bash
grep -c 'dispatch.sh' skills/writing-plans/SKILL.md
grep -nE 'CODEX_COMPANION|<<.?PROMPT|mktemp' skills/writing-plans/SKILL.md && echo "LEFTOVER" || echo "CLEAN"
```
Expected: non-zero `dispatch.sh` count; `CLEAN`.

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

- [ ] **Step 1: Replace the dispatch wording** in the "Spec Review Loop (Dual Reviewer, codex companion)" section with:

````markdown
**Dispatch mechanism (shared `dispatch.sh`, run from repo root).** `dispatch.sh`, `--prompt`,
and `--focus` are plugin-bundled (absolute via `${CLAUDE_PLUGIN_ROOT}`); the spec path is
repo-root-relative. **Pre-dispatch guard:** if the resolved path still contains a literal
`${CLAUDE_PLUGIN_ROOT}` or `dispatch.sh` is missing/not executable, STOP and require
`/plugin install` — do not fall back to inline self-review.

Reviewer 1 — Structural Completeness (`run_in_background: true`):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/brainstorming/spec-document-reviewer-prompt.md" \
  --set SPEC_FILE_PATH=docs/superpowers/specs/<YYYY-MM-DD-topic>-design.md
```

Reviewer 2 — Design Soundness (`run_in_background: true`):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" adversarial \
  --base "$SPEC_BASE" \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/brainstorming/adversarial-spec-review-focus.md"
```
````

- [ ] **Step 2: Verify**

Run:
```bash
grep -c 'dispatch.sh' skills/brainstorming/SKILL.md
grep -nE 'CODEX_COMPANION|<<.?PROMPT|mktemp' skills/brainstorming/SKILL.md && echo "LEFTOVER" || echo "CLEAN"
```
Expected: non-zero count; `CLEAN`.

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

- [ ] **Step 1: Add the spec-compliance dispatch with the report-file step.** Where the SKILL describes dispatching reviewer 5 (spec compliance), insert:

````markdown
**Dispatch mechanism (shared `dispatch.sh`, run from repo root).** Same pre-dispatch guard
as the other skills: if the resolved path still contains a literal `${CLAUDE_PLUGIN_ROOT}`
or `dispatch.sh` is missing/not executable, STOP and require `/plugin install`.

Spec compliance reviewer (reviewer 5). First write the implementer's report to a **unique**
temp file (one per reviewer, never shared), then pass it with `--report-file`. Delete the
source temp file only **after this dispatch completes** (its completion notification):

```bash
REPORT_FILE="$(mktemp)"
# write the implementer's verbatim report into "$REPORT_FILE" (e.g. via a heredoc or the Write tool)
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/spec-reviewer-prompt.md" \
  --report-file "$REPORT_FILE" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/<YYYY-MM-DD-topic>-plan.md \
  --set TASK_ID="Task N" \
  --set TASK_BASE="$TASK_BASE"
# after the dispatch completes: rm -f "$REPORT_FILE"
```

`dispatch.sh` copies the report into its own private temp and injects that private path,
so the reviewer's access does not depend on when you delete `$REPORT_FILE`.
````

- [ ] **Step 2: Replace reviewer 6 (code quality) dispatch** with:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" review --base "$TASK_BASE"
```

- [ ] **Step 3: Replace reviewer 7 (final) dispatch** with:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" adversarial \
  --base "$IMPL_BASE" \
  --focus "${CLAUDE_PLUGIN_ROOT}/skills/subagent-driven-development/final-code-reviewer-focus.md"
```

- [ ] **Step 4: Verify**

Run:
```bash
grep -c 'dispatch.sh' skills/subagent-driven-development/SKILL.md
grep -c -- '--report-file' skills/subagent-driven-development/SKILL.md
grep -nE 'CODEX_COMPANION|<<.?PROMPT' skills/subagent-driven-development/SKILL.md && echo "LEFTOVER" || echo "CLEAN"
```
Expected: non-zero `dispatch.sh` count; `--report-file` count ≥ 1; `CLEAN`. (Note: `implementer-prompt.md` still uses its own heredoc — that file is NOT edited; the `CLEAN` grep targets SKILL.md only.)

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

- [ ] **Step 2: Add an "Install" section:**

```markdown
## Install

```bash
/plugin marketplace add stu43005/superpowers-codex
/plugin install superpowers-codex
```
```

- [ ] **Step 3: Add a "Migrating from a skills-collection install" section:**

```markdown
## Migrating from a skills-collection install

Earlier versions were dropped into `~/.claude/skills/`. A leftover copy can **shadow** the
plugin, so its `SKILL.md` (and the dispatch guard inside it) would never load. Before/after
installing the plugin you MUST remove legacy copies and verify nothing shadows it:

```bash
# 1. Remove legacy copies (and any ~/.agents/skills symlink targets)
rm -rf ~/.claude/skills/{brainstorming,writing-plans,subagent-driven-development,finishing-a-development-branch}

# 2. Run the preflight — it fails if any legacy copy remains
"${CLAUDE_PLUGIN_ROOT}/scripts/preflight-plugin-install.sh"
```

The preflight exits non-zero and names any offending path. Migration is complete only once
it passes. (Discovery-precedence result and whether `/plugin install` runs the preflight
automatically are recorded by the verification task — see the plan's Task 15.)
```

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
- Modify (append results): `README.md` (discovery-precedence result + preflight auto-run finding)

This task runs the spec §8 checks that require a live environment. Record empirical results; wire the auto-hook only if supported.

- [ ] **Step 1: Static + unit checks (re-run aggregate)**

Run:
```bash
bash -n scripts/dispatch.sh && bash -n scripts/preflight-plugin-install.sh
command -v shellcheck >/dev/null && shellcheck scripts/dispatch.sh scripts/preflight-plugin-install.sh || echo "shellcheck not installed; relying on bash -n + test runners"
bash scripts/dispatch.test.sh
bash scripts/preflight.test.sh
```
Expected: both test runners report `0 failed` (exit 0).

- [ ] **Step 2: `--dry-run` matrix for every reviewer invocation**

Run (from repo root), using the real spec/plan files as existing path values:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" task \
  --prompt "${CLAUDE_PLUGIN_ROOT}/skills/writing-plans/plan-document-reviewer-prompt.md" \
  --set PLAN_FILE_PATH=docs/superpowers/plans/2026-06-15-reviewer-dispatch-plugin.md \
  --set SPEC_FILE_PATH=docs/superpowers/specs/2026-06-15-reviewer-dispatch-plugin-design.md \
  --set TASK_ID="Task 2" --dry-run
```
Expected: prints the resolved `node … task --prompt-file …` command and the fully-substituted prompt; no `[UPPER_CASE]` placeholder remains in the printed prompt. Repeat for `coverage-verifier`, `spec-document-reviewer` (spec only), and the `review`/`adversarial` dry-runs.

- [ ] **Step 3: Companion version guard**

Run (simulate an old version by checking the comparison logic directly):
```bash
bash -c 'source scripts/dispatch.sh 2>/dev/null; :' 2>/dev/null || true
# Functional check: a path with an older version segment must fail the guard.
# (Manual: temporarily point resolution at a fake .../codex/0.9.0/scripts/codex-companion.mjs and confirm non-zero + /codex:setup message.)
```
Expected: a `0.9.0`-segment path → non-zero exit citing `< required 1.0.4` and `/codex:setup`; the real `1.0.4` path → passes.

- [ ] **Step 4: Discovery-precedence empirical determination**

Create coexisting copies and determine which the running Claude Code loads:
```bash
# With the plugin installed, also create a legacy copy and observe which SKILL.md loads.
mkdir -p ~/.claude/skills/writing-plans
# (mark the legacy SKILL.md with a unique sentinel, invoke the skill, observe which loads)
```
Record the result (plugin-wins vs legacy-wins) in README's migration section. Then remove the legacy copy.

- [ ] **Step 5: Preflight auto-run determination**

Determine whether `/plugin install` can run `preflight-plugin-install.sh` automatically via a plugin hook (consult Claude Code plugin docs). If yes, declare the hook in `plugin.json` and verify install fails on a shadowing legacy path. If no, confirm README mandates the manual preflight command and note the limitation in README.

- [ ] **Step 6: Plugin install smoke test**

```bash
/plugin marketplace add stu43005/superpowers-codex
/plugin install superpowers-codex
```
Then invoke a skill (e.g. brainstorming) and confirm `${CLAUDE_PLUGIN_ROOT}` expands to the plugin cache path and `dispatch.sh` is locatable/executable from a real reviewer dispatch (a `--dry-run` invocation through the installed skill).

- [ ] **Step 7: Migration shadow smoke test**

With a legacy `~/.claude/skills/writing-plans` present, run the preflight and confirm it exits non-zero naming the path; remove it and confirm the plugin SKILL.md loads and dispatch works.

- [ ] **Step 8: Commit any recorded results**

```bash
git add README.md
git commit -m "docs: record discovery precedence and preflight auto-run findings"
```

---

## Done criteria

- `scripts/dispatch.test.sh` and `scripts/preflight.test.sh` pass (0 failed).
- `bash -n` (and `shellcheck` where available) clean on both scripts.
- Every reviewer `--dry-run` produces a placeholder-free prompt and a correct companion command.
- The seven prompt files are slimmed/converted; the two focus sidecars exist; the three SKILL.md files dispatch via `dispatch.sh`; `implementer-prompt.md` is untouched.
- Plugin installs; `${CLAUDE_PLUGIN_ROOT}` expands; the preflight blocks a shadowing legacy install; README documents install + migration with the recorded precedence/auto-run results.
