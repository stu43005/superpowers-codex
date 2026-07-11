# Anti-Over-Engineering Escape Valve — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-codex:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an anti-over-engineering escape valve to the `brainstorming` skill's spec review loop and a matching carve-out to `subagent-driven-development`'s final adversarial gate, so a purely adversarial reviewer can no longer drive endless over-engineering.

**Architecture:** Both target files are Markdown instruction files that ARE the plugin's shipped runtime behavior (per this repo's CLAUDE.md, `skills/**/*.md` is product code, not docs). The change edits prose/pseudocode: a per-round ledger, two escalation triggers routing to `AskUserQuestion`, a relaxed exit condition where user-adjudicated-reject topics are non-blocking, a Non-goals/Accepted-limitations recording structure, and a downstream carve-out that lets the final gate honor spec-adjudicated rejections. The inserted instructions are written in **English** to match the existing SKILL.md files (the繁中 spec is the design source; the shipped instructions stay English).

**Tech Stack:** Markdown (skill instruction files). No executable code changes. Existing hermetic bash test suite (`scripts/*.test.sh`) is used only as a regression guard because no wrapper scripts change.

**Verification approach (why no new automated tests):** these files have no runtime surface a unit test could exercise — they are instructions an LLM agent reads. Verification is therefore: (a) exact-string grep presence/absence checks per edit, (b) running the unchanged wrappers' existing test suite as a regression guard, and (c) a final internal-consistency read-through. Building a test harness for prose would itself be the over-engineering this feature exists to prevent.

**Source spec:** `docs/superpowers/specs/2026-07-11-review-loop-overengineering-escape-valve-design.md`

---

## File Structure

- **Modify:** `skills/brainstorming/SKILL.md` — main change. New escape-valve subsection (ledger + triggers + rejection recording) in the "Spec Review Loop" region; the "Round loop" block rewritten; Checklist item 6 and the Process Flow diagram updated for consistency.
- **Modify:** `skills/subagent-driven-development/SKILL.md` — downstream carve-out in the "Final adversarial reviewer" section; the "Zero tolerance" line softened to reference it.
- **Unchanged (regression guard only):** `scripts/review-brainstorm.sh`, `scripts/review-final.sh`, `scripts/review-batch-lib.sh`, all reviewer prompt/focus `.md` files, and `scripts/*.test.sh`.

Task order: Tasks 1–4 edit `brainstorming/SKILL.md` in place (do them in order — later anchors assume earlier edits landed but target disjoint regions, so they are independent); Task 5 edits `subagent-driven-development/SKILL.md`; Task 6 is whole-repo regression + consistency verification.

---

### Task 1: brainstorming — add the escape-valve subsection (ledger + triggers + rejection recording)

**Files:**
- Modify: `skills/brainstorming/SKILL.md` (insert after the "Design Soundness reviewer" description, before "Single batched dispatch per round")

- [ ] **Step 1: Insert the escape-valve subsection**

Find this exact text (the Design Soundness reviewer description):

```markdown
**Design Soundness reviewer** (read-only):
Challenges design-level soundness: failure paths / partial failure / rollback, concurrency and ordering assumptions, boundary and empty states, compatibility / migration risk, unstated critical assumptions. Returns `Verdict: approve` or `Verdict: needs-attention`.
```

Replace it with that same text followed by the new subsection:

```markdown
**Design Soundness reviewer** (read-only):
Challenges design-level soundness: failure paths / partial failure / rollback, concurrency and ordering assumptions, boundary and empty states, compatibility / migration risk, unstated critical assumptions. Returns `Verdict: approve` or `Verdict: needs-attention`.

**Escape valve for design-soundness findings (anti-over-engineering):**

The design-soundness reviewer is adversarial by construction, so it will always find "you could be more rigorous." Blindly fixing every finding drives over-engineering: writing atomicity, deploy/rollback machinery, or parsers for near-impossible edge cases that a small tool does not need or that another mechanism already covers. The escape valve hands the "is this concern worth the cost?" judgment back to the user instead of letting the loop escalate rigor without bound. It applies **only to design-soundness findings** — structural-completeness stays zero-tolerance.

**Per-round ledger (required):** Each round, after parsing `=== Summary ===`, maintain a visible ledger table in your reply and update it every round:

| Topic | Consecutive rounds flagged | Status |
|---|---|---|
| semantic summary of the concern | N | `open` / `adjudicated-implement` / `adjudicated-reject` |

- **Topic** is judged *semantically* — a reviewer rewording the same root concern across rounds is the same topic, and its round count accumulates.
- **Consecutive rounds flagged** counts consecutive rounds the topic appears in design-soundness findings; a round in which it is not flagged resets it to zero.
- **Status:** `open` (not yet adjudicated), `adjudicated-implement` (user chose to fix it), `adjudicated-reject` (user chose not to; recorded in the spec's Non-goals / Accepted limitations).

The ledger is an in-session heuristic tracker, re-emitted in full each round from the current round's reviewer output — it is not durable repo state (the `adjudicated-reject` decisions themselves live durably in the spec). **Fail-closed degradation:** if context compaction or agent handoff makes a topic's consecutive count uncertain *and* the topic is still being flagged this round, escalate via `AskUserQuestion` rather than silently resetting the count and continuing to fight — underestimating the count would defeat the backstop. The subjective trigger and the structural-completeness reviewer are unaffected by a lost count.

**Two escalation triggers — both route to `AskUserQuestion`; never self-adjudicate an "accepted limitation."** Whether to accept a concern is the user's call; your job is to detect and escalate, not to decide YAGNI for the user.

- **Subjective (early, discretionary):** if you judge a design-soundness finding may be over-engineering — disproportionate to this project's actual scale, aimed at a near-impossible edge case, or already covered by another mechanism — escalate *immediately* via `AskUserQuestion`. Do not silently fix it and do not silently skip it.
- **Objective (mandatory backstop):** if the ledger shows an `open` topic flagged for **three consecutive rounds**, you **must** escalate via `AskUserQuestion`, even if each round's fix felt reasonable.

At escalation, present the specific finding, why you suspect over-engineering (or that it has been fought three rounds, with the ledger count), and roughly what implementing it would cost. Offer two choices: **Implement** (reviewer is right → fix it; topic becomes `adjudicated-implement`) or **Don't implement** (record it as an explicit accepted limitation with the user's rationale in the spec; topic becomes `adjudicated-reject`). The auto-added "Other" lets the user propose a middle ground; handle per their instruction and record the topic as `adjudicated-implement` or `adjudicated-reject` accordingly.

**Recording adjudicated rejections (Non-goals / Accepted limitations):** when the user adjudicates a concern as `adjudicated-reject`, record it in a **Non-goals / Accepted limitations** section of the spec being written, one entry each — **Concern** (the reviewer's concern, summarized), **Decision** (not implemented), **Rationale** (why not: disproportionate to scale / already covered by another mechanism / a near-impossible edge case, as the user stated). This is a durable record: it survives context compaction and is the basis for downstream adversarial acceptance (see `subagent-driven-development`). Reuse an existing equivalent section (e.g. a "Non-goals" heading) if the spec already has one. **Scope / stale-waiver guard:** each rejection is scoped to the design premise under which it was made; if later spec edits materially change that premise (e.g. the cost structure judged "disproportionate," or the other mechanism that covered it), the rejection no longer auto-applies — treat the concern as a fresh issue and route it back through the normal loop.
```

- [ ] **Step 2: Verify the new content is present**

Run: `grep -c "Escape valve for design-soundness findings" skills/brainstorming/SKILL.md`
Expected: `1`

Run: `grep -c "Two escalation triggers\|three consecutive rounds\|Fail-closed degradation\|Recording adjudicated rejections" skills/brainstorming/SKILL.md`
Expected: `4`

- [ ] **Step 3: Verify the original reviewer description is intact (not duplicated/broken)**

Run: `grep -c "Returns \`Verdict: approve\` or \`Verdict: needs-attention\`." skills/brainstorming/SKILL.md`
Expected: `1`

- [ ] **Step 4: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "feat: add escape-valve ledger and escalation triggers to brainstorming review loop"
```

---

### Task 2: brainstorming — rewrite the "Round loop" block for the escape valve

**Files:**
- Modify: `skills/brainstorming/SKILL.md` (replace the "Round loop — zero tolerance:" heading, pseudocode block, and its trailing paragraph)

- [ ] **Step 1: Replace the round-loop block**

Find this exact block:

````markdown
**Round loop — zero tolerance:**

```
while true:
  summary = run_review_brainstorm(spec_file, SPEC_BASE)   # ONE wrapper call, both reviewers
  parse === Summary ===   # read stdout on ANY exit code (stdout is authoritative)
  structural = structural_completeness verdict   # Status: OKAY | Issues Found | ERROR (tool failed…)
  design     = design_soundness verdict          # Verdict: approve | needs-attention | ERROR (tool failed…) | prose

  if structural is "ERROR (tool failed…)" OR design is "ERROR (tool failed…)":
    continue   # tool failure, NOT a review result — re-run the WHOLE wrapper, same args

  if structural == "Status: OKAY" AND design == "Verdict: approve":
    break   # both passed — exit loop

  # Only real reviewer findings (Issues Found / needs-attention, and any prose finding) reach here.
  fix_all_findings(structural.issues + design.findings)   # every finding — none skipped
  commit_round_fixes()
  # spec was edited — re-run the whole wrapper next round (both reviewers re-run together)
```

Any finding from either reviewer blocks the round. An `ERROR (tool failed…)` is a tool failure,
not a finding: re-run the whole wrapper rather than entering the fix loop. Fix every real finding
before re-running.
````

Replace it with:

````markdown
**Round loop — structural zero-tolerance + design escape valve:**

```
while true:
  summary = run_review_brainstorm(spec_file, SPEC_BASE)   # ONE wrapper call, both reviewers
  parse === Summary ===   # read stdout on ANY exit code (stdout is authoritative)
  structural = structural_completeness verdict   # Status: OKAY | Issues Found | ERROR (tool failed…)
  design     = design_soundness verdict          # Verdict: approve | needs-attention | ERROR (tool failed…) | prose
  update_ledger(design.findings)                 # per-round ledger; semantic topics; fail-closed on uncertain counts

  if structural is "ERROR (tool failed…)" OR design is "ERROR (tool failed…)":
    continue   # tool failure, NOT a review result — re-run the WHOLE wrapper, same args

  # Exit condition. structural is always zero-tolerance; design gets the escape valve.
  if structural == "Status: OKAY" AND (
        design == "Verdict: approve"
        OR every remaining design finding maps to an `adjudicated-reject` ledger topic):
    break   # both passed, OR the only remaining design findings are user-rejected topics

  if structural == "Status: Issues Found":
    fix_all_structural_issues()          # structural findings: always fix (zero tolerance)

  for finding in design.findings:        # design findings: escape valve applies
    topic = ledger_topic(finding)
    if topic.status == "adjudicated-reject":
      continue                           # non-blocking — do not re-fix, do not re-escalate
    if subjective_over_engineering(finding) OR topic.consecutive_rounds == 3:
      adjudicate_with_user(topic)        # AskUserQuestion → adjudicated-implement | adjudicated-reject
    else:
      fix_finding(finding)               # attempt the fix this round

  commit_round_fixes()
  # spec was edited — re-run the whole wrapper next round (both reviewers re-run together)
```

Structural-completeness stays zero-tolerance: its `Issues Found` are always fixed. The escape valve applies only to design-soundness findings. A topic the user adjudicated `adjudicated-reject` is non-blocking on all later rounds — do not re-fix or re-escalate it; the loop can exit once structural is `Status: OKAY` and every remaining design finding maps to an `adjudicated-reject` topic, **even if design-soundness never returns `approve`**. An `ERROR (tool failed…)` is a tool failure, not a finding: re-run the whole wrapper rather than entering the fix loop.
````

- [ ] **Step 2: Verify the new block is present and the old framing is gone**

Run: `grep -c "structural zero-tolerance + design escape valve" skills/brainstorming/SKILL.md`
Expected: `1`

Run: `grep -c "even if design-soundness never returns" skills/brainstorming/SKILL.md`
Expected: `1`

Run: `grep -c "fix_all_findings(structural.issues + design.findings)" skills/brainstorming/SKILL.md`
Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "feat: rewrite brainstorming round loop with relaxed design-soundness exit"
```

---

### Task 3: brainstorming — update Checklist item 6 and the Process Flow diagram

**Files:**
- Modify: `skills/brainstorming/SKILL.md` (Checklist item 6; Process Flow dot graph edges)

- [ ] **Step 1: Replace Checklist item 6**

Find this exact line:

```markdown
6. **Spec review loop (dual reviewer, codex)** — capture `SPEC_BASE` before writing the spec; after committing, dispatch both reviewers each round with ONE `review-brainstorm.sh` call (it runs the structural-completeness and design-soundness reviewers in parallel); read the wrapper's stdout `=== Summary ===` on any exit code; fix ALL findings; loop until the structural-completeness reviewer returns `Status: OKAY` AND the design-soundness reviewer returns `Verdict: approve` in the same round (see below — do NOT do this inline)
```

Replace it with:

```markdown
6. **Spec review loop (dual reviewer, codex)** — capture `SPEC_BASE` before writing the spec; after committing, dispatch both reviewers each round with ONE `review-brainstorm.sh` call (it runs the structural-completeness and design-soundness reviewers in parallel); read the wrapper's stdout `=== Summary ===` on any exit code; maintain the per-round ledger; fix ALL structural-completeness findings; for design-soundness findings apply the escape valve (escalate suspected over-engineering, or any topic flagged three consecutive rounds, via `AskUserQuestion`; `adjudicated-reject` topics are non-blocking); loop until structural-completeness is `Status: OKAY` AND design-soundness is `Verdict: approve` — or the only remaining design findings map to `adjudicated-reject` topics — in the same round (see below — do NOT do this inline)
```

- [ ] **Step 2: Add an escalation node to the Process Flow dot graph**

Find this exact line:

```
    "Invoke superpowers-codex:writing-plans" [shape=doublecircle];
```

Replace it with:

```
    "Invoke superpowers-codex:writing-plans" [shape=doublecircle];
    "Escalate to user\n(AskUserQuestion)" [shape=diamond];
```

- [ ] **Step 3: Rewrite the review-loop self-edge and exit edge, and add the escalation edges**

Find these exact two lines:

```
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [label="any finding — fix all, re-run wrapper"];
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "User reviews spec?" [label="both OKAY + approve"];
```

Replace them with:

```
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [label="structural finding — fix; design finding — fix"];
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "Escalate to user\n(AskUserQuestion)" [label="design finding: over-engineering suspected\nor 3-round backstop"];
    "Escalate to user\n(AskUserQuestion)" -> "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" [label="adjudicated (implement / reject)"];
    "Spec review loop\n(review-brainstorm.sh: structural-completeness + design-soundness\nboth parallel, both must pass)" -> "User reviews spec?" [label="structural OKAY + (approve OR remaining design all adjudicated-reject)"];
```

- [ ] **Step 4: Verify the diagram and checklist edits**

Run: `grep -c "Escalate to user" skills/brainstorming/SKILL.md`
Expected: `3` (one node declaration + two edges)

Run: `grep -c "remaining design all adjudicated-reject" skills/brainstorming/SKILL.md`
Expected: `1`

Run: `grep -c "for design-soundness findings apply the escape valve" skills/brainstorming/SKILL.md`
Expected: `1`

Run: `grep -c "fix ALL findings; loop until the structural-completeness reviewer returns" skills/brainstorming/SKILL.md`
Expected: `0` (old checklist wording removed)

- [ ] **Step 5: Commit**

```bash
git add skills/brainstorming/SKILL.md
git commit -m "feat: update brainstorming checklist and flow diagram for the escape valve"
```

---

### Task 4: subagent-driven-development — final-gate carve-out for spec-adjudicated rejections

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md` (in "Final adversarial reviewer": add the carve-out before "Caller HEAD contract"; soften the "Zero tolerance" line)

- [ ] **Step 1: Insert the carve-out paragraph before the Caller HEAD contract**

Find this exact text:

```markdown
**Caller HEAD contract:** Do not advance `HEAD` while `review-final.sh` is running — the reviewer
diffs `<IMPL_BASE>..HEAD`. Commit any fixes before re-running the gate, not while it runs.
```

Replace it with:

```markdown
**Respect spec-adjudicated rejections (narrow carve-out):** Before fixing final-adversarial findings, read the **Non-goals / Accepted limitations** section of the spec this plan was derived from. If a finding is *clearly the same concern* as an item the spec records there as an accepted limitation (an `adjudicated-reject` from brainstorming), treat that finding as **non-blocking** — do not implement it, and note in your report which accepted limitation it maps to (quote the recorded concern). This does not ask the user; it honors a decision the user already made.

- **Conservative matching (this bypasses the merge gate — fail safe):** suppress only when the finding is clearly the same concern the user rejected. If the overlap is partial, the scope differs, or the match is ambiguous, **default to blocking** and handle it as a normal finding.
- **Premise check before suppression:** before suppressing, state in your report the premise the accepted limitation rested on (its recorded rationale) and confirm it still holds for the current implementation. If implementation drift changed that premise, or you cannot confirm it holds, the rejection has lapsed — the finding **blocks** as normal.
- All findings not covered by a spec-adjudicated rejection are handled exactly as before.

**Caller HEAD contract:** Do not advance `HEAD` while `review-final.sh` is running — the reviewer
diffs `<IMPL_BASE>..HEAD`. Commit any fixes before re-running the gate, not while it runs.
```

- [ ] **Step 2: Soften the trailing zero-tolerance line to reference the carve-out**

Find this exact line (the one at the end of the "Final adversarial reviewer" section — note the identical sentence also appears earlier under the per-task review section, so match the full line including surrounding context):

```markdown
**Zero tolerance; do not ask the user** — the loop runs automatically until the gate clears.
```

There are two occurrences of "the loop runs automatically until the gate clears" in the file; only the standalone bolded line above is the final-gate one. Replace that bolded line with:

```markdown
**Zero tolerance, except spec-adjudicated rejections above; do not ask the user** — the loop runs automatically until the gate clears.
```

- [ ] **Step 3: Verify the carve-out is present and correctly placed**

Run: `grep -c "Respect spec-adjudicated rejections (narrow carve-out)" skills/subagent-driven-development/SKILL.md`
Expected: `1`

Run: `grep -c "Conservative matching (this bypasses the merge gate\|Premise check before suppression" skills/subagent-driven-development/SKILL.md`
Expected: `2`

Run: `grep -c "Zero tolerance, except spec-adjudicated rejections above; do not ask the user" skills/subagent-driven-development/SKILL.md`
Expected: `1`

Run: `grep -n "Respect spec-adjudicated rejections" skills/subagent-driven-development/SKILL.md`
Expected: a line number that appears BEFORE the `grep -n "Caller HEAD contract" skills/subagent-driven-development/SKILL.md` line number (carve-out sits just above the HEAD contract). Confirm by comparing the two line numbers.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: honor spec-adjudicated rejections at the final adversarial gate"
```

---

### Task 5: Regression + internal-consistency verification

**Files:**
- Test (regression, unchanged): `scripts/review-batch-lib.test.sh`, `scripts/dispatch.test.sh`, `scripts/preflight.test.sh`
- Review (read-only): `skills/brainstorming/SKILL.md`, `skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: Run the existing wrapper test suite (regression guard)**

Run:
```bash
for f in scripts/*.test.sh; do echo "== $f =="; bash "$f" || echo "SUITE FAILED: $f"; done
```
Expected: each suite prints its `ok - ...` lines and no `SUITE FAILED` / `FAIL -` lines. Since no scripts changed, all suites must still pass.

- [ ] **Step 2: Confirm no stale contradictory wording remains in brainstorming/SKILL.md**

Run: `grep -n "zero tolerance\|zero-tolerance\|Zero tolerance" skills/brainstorming/SKILL.md`
Expected: only the new "structural zero-tolerance + design escape valve" heading and any structural-completeness-scoped mention remain; NO surviving text claims that ALL design-soundness findings must be fixed to reach `approve`. If any line still asserts unconditional "fix ALL findings … until … `Verdict: approve`" for design-soundness, fix it to match the escape valve.

- [ ] **Step 3: Internal-consistency read-through**

Read the full "Spec Review Loop" region of `skills/brainstorming/SKILL.md` and the "Final adversarial reviewer" section of `skills/subagent-driven-development/SKILL.md`. Confirm, as a checklist:
- The ledger, the two triggers, the relaxed exit condition, and the Non-goals recording structure are mutually consistent (same status names: `open`, `adjudicated-implement`, `adjudicated-reject`).
- The Process Flow diagram edges match the prose (escalation node present; exit edge mentions the adjudicated-reject path).
- The subagent-driven-development carve-out references the same "Non-goals / Accepted limitations" section name that brainstorming writes.
- No leftover references to the removed `implementing` / `implemented-verified` states (those were never in scope; grep to be sure):

Run: `grep -c "implemented-verified\|\`implementing\`" skills/brainstorming/SKILL.md`
Expected: `0`

- [ ] **Step 4: Commit any consistency fixes (only if Step 2 or 3 required edits)**

```bash
git add skills/brainstorming/SKILL.md skills/subagent-driven-development/SKILL.md
git commit -m "fix: resolve internal-consistency wording in escape-valve edits"
```

If Steps 2–3 required no edits, skip this commit.

---

## Done criteria

- `skills/brainstorming/SKILL.md`: escape-valve subsection, rewritten round loop, updated checklist item 6, and updated flow diagram are all present and mutually consistent.
- `skills/subagent-driven-development/SKILL.md`: final-gate carve-out present with conservative matching + premise check; zero-tolerance line references it.
- All `scripts/*.test.sh` suites pass (regression guard; no scripts changed).
- No surviving wording contradicts the escape valve.
