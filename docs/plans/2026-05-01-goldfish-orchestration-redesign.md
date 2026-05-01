# Goldfish Orchestration Redesign Implementation Plan

**Goal:** Restructure goldfish testing orchestration so the `run-goldfish-test` skill is the single canonical source of protocol logic, commands become thin wrappers that delegate to it, and the protocol itself gains a two-step triage framework, fix-forward re-run strategy, and conditional verification cycle.

**Architecture:** Four files change: the skill gains new Triage Decision Framework and revised Re-run Strategy sections (replacing the old Caller Review Protocol); `goldfish-test.md` is slimmed to a skill-loading wrapper; `build-feature.md` and `write-plan.md` have their inline gates replaced with the standard thin conditional phase. All other files are unchanged.

**Tech Stack:** Markdown, YAML frontmatter, OpenCode skills/commands.

**Runtime assumptions (documented, not gaps):**
1. `~/.config/opencode/skills/` and `~/.config/opencode/commands/` are directory symlinks pointing to `external/opencode/`. This is established dotfiles repo convention; Task 5 verifies it by reading the runtime path directly.
2. Skill availability is determined by the OpenCode platform: at session start, agents see the list of available skills. Commands using "if the skill is available" rely on this standard mechanism — no special detection is needed.
3. Each task begins with "Read the current file" (Step 1). All section anchors used in edit steps are verified against the actual file content at that point; they were correct at authoring time and are expected to remain so.

---

### Task 1: Rewrite `run-goldfish-test/SKILL.md`

**Files:**
- Modify: `external/opencode/skills/run-goldfish-test/SKILL.md`

**Step 1: Read the current file**

Read `external/opencode/skills/run-goldfish-test/SKILL.md` and `docs/plans/2026-05-01-goldfish-orchestration-redesign-design.md` (the target skill structure is in the "Revised `run-goldfish-test` Skill Structure" section of the design doc).

**Step 2: Update the frontmatter description**

The current description references "Caller Review Protocol." Replace the entire frontmatter with:

```yaml
---
name: run-goldfish-test
description: Use when orchestrating the full goldfish quality gate — preparing an
  artifact, dispatching all three evaluation passes, applying the triage decision
  framework to any flags, and issuing the certified verdict. Not for acting as a
  per-pass evaluator.
---
```

**Step 3: Replace the `Failure handling` paragraph**

Locate (under `## Failure Conditions`):

```
**Failure handling:** Any pass failure = hard stop. Review the findings, update the
artifact if needed, then re-run all three passes from Pass 1. A revised artifact is a
new artifact — no partial credit carries over.
```

Replace with:

```
**Failure handling:** See Re-run Strategy below for the full protocol. The key
principles: auto-resolvable findings do not require a restart; human-prompted fixes
(substantive changes) do. A revised artifact is a new artifact — no partial credit
carries over.
```

**Step 4: Add `## Triage Decision Framework` section after `## Pass Prompts`**

Insert the following new section between the end of `## Pass Prompts` (after the Pass 3 prompt block) and `## Verdict`:

```markdown
## Triage Decision Framework

The orchestrator processes each goldfish finding in two steps: validity classification,
then triage.

### Step 1 — Validity Classification

Using its broader context (conversation history, user intent, project knowledge), the
orchestrator determines whether each finding is valid. Context is valid grounds for
dismissal only when that context is also available to the next consumer of the artifact
— i.e., it is documented within the artifact's own scope. If the relevant context
exists only in the current conversation, the procedure is: add it to the artifact
first, then the finding can be resolved as invalid (missing context).

- **Valid:** The finding identifies a real gap or issue in the artifact. Proceed to
  Step 2.
- **Invalid (missing context):** The finding is wrong because the goldfish lacked
  context, and that context is now artifact-local (already documented or just added).
  Auto-resolve: add the minimum clarifying context to the artifact to prevent
  re-flagging. This context addition must be non-substantive — it must not change the
  artifact's meaning, only its clarity. If the required clarification would change
  meaning, reclassify the finding as valid and send it to Step 2.
- **Invalid (non-issue/misreading):** The finding is factually incorrect or irrelevant.
  Auto-resolve: add a note to the Assumptions & Non-Issues section. No other artifact
  change needed.

Invalid findings are always auto-resolved. They do not reach Step 2.

### Step 2 — Triage Matrix (valid findings only)

The orchestrator classifies each valid finding along two axes:

**Resolution certainty:** Is there exactly one correct fix, or are there multiple valid
approaches?

**Impact scope:** Does the fix change the artifact's meaning/intent, or only its
clarity (surface presentation, wording, and formatting)?

| | Single clear fix | Multiple valid approaches |
|---|---|---|
| **Clarity only** | Auto-resolve | Prompt human |
| **Changes meaning/intent** | Prompt human | Prompt human |

The matrix is the single authoritative decision procedure. The category lists below are
examples within the matrix's cells, not additional rules. If an example appears to
conflict with the matrix, the matrix governs.

### Auto-Resolve Examples

These are findings that land in the matrix's "single clear fix + clarity only" cell:

- **Surface corrections.** Fixing typos, formatting, or phrasing flagged by the goldfish.
- **Context additions.** Adding minimal clarifying text to prevent re-flagging.
- **Single-solution fixes.** Any valid finding with exactly one unambiguous,
  high-certainty resolution that does not change the artifact's meaning or intent.

### Human-Prompt Examples

These are findings that land in one of the matrix's "prompt human" cells:

- **Ambiguous resolution path.** The finding requires choosing between multiple valid
  approaches.
- **Scope/intent change.** The resolution would alter what the artifact is about or who
  it's for.
- **Insufficient context.** The finding reveals a genuine gap the orchestrator doesn't
  have enough context to resolve.
- **Challenged deliberate choice.** The goldfish questions something that may have been
  an intentional author decision, but the orchestrator can't determine whether it was
  deliberate.

### Orchestrator Context Advantage

The orchestrator has information the goldfish evaluator does not: full conversation
history, the user's stated intent, awareness of the broader project context, and
knowledge of other artifacts in the system. It uses this in both steps — to classify
validity (Step 1) and to assess impact scope and resolution certainty (Step 2).
```

**Step 5: Replace `## Caller Review Protocol` with `## Re-run Strategy`**

Remove the entire `## Caller Review Protocol` section and replace it with the content below. The resulting section must be positioned immediately before `## Verdict` in the file — if the current `## Caller Review Protocol` is not immediately before `## Verdict`, move the replacement to that position after inserting it.

```markdown
## Re-run Strategy

### During Initial Pass-Through (Passes 1→2→3)

When a pass fails, the orchestrator triages each finding using the Triage Decision
Framework above:

1. **Auto-resolvable findings only:** Apply all auto-fixes, then continue to the next
   pass. Do NOT restart from Pass 1.
2. **Human-prompt findings only:** Stop, present findings to the user, wait for
   resolution. After user resolves: restart from Pass 1 (substantive change = new
   artifact).
3. **Mixed (both types in the same pass):** Apply all auto-fixes first, then stop and
   present the human-prompt findings to the user. The user sees the already-improved
   artifact. After user resolves: restart from Pass 1.

### Pass 2 Minor Findings

Pass 2 minor findings are collected during the pass-through regardless of whether Pass
2 passes or fails, and are printed with the final verdict. They do not trigger re-runs
or human prompts. The term "minor" means non-blocking: a minor finding does not cause
Pass 2 to fail (only critical findings do), but it is still collected and reported even
if Pass 2 also raises a critical finding in the same run. Minor findings are a separate
output channel from the triage flow, which only applies to findings that caused a pass
to fail. Minor findings from the initial cycle are printed; if the verification re-run
also runs Pass 2, any new minor findings from that run replace the initial set.

### Conditional Verification Re-run

After all three passes complete:

- If **any auto-resolved fixes** were applied during the pass-through: run one full
  verification cycle (all three passes) on the final artifact state.
- If all three passes were clean on first try (no fixes needed): skip the verification
  re-run and issue the verdict immediately.

### Loop Cap

To prevent infinite loops: after 2 full cycles (initial + verification) with continued
failures, apply any auto-resolvable fixes from cycle 2, then stop and prompt the human
regardless of triage category. Something structural is wrong if minor fixes keep
cascading.
```

**Step 6: Update `## Rationalization Table`**

Add two rows to the **end** of the existing table:

```markdown
| "This fix is minor, I can skip the verification re-run" | Auto-fixes accumulate. The verification re-run exists to catch coherence issues they introduce. Skip it and you may certify a broken artifact. |
| "Pass 2 only had minor findings, those are fine to ignore" | Minor findings are printed for a reason. If they're truly ignorable, they'll pass the verification re-run. If they don't, they weren't minor. |
```

**Step 7: Verify the file**

Read the updated `SKILL.md`. Confirm:
- `## Triage Decision Framework` section is present with both Step 1 and Step 2
- `## Re-run Strategy` section is present immediately before `## Verdict`, with all three pass-handling cases, minor findings, verification re-run, and loop cap
- `## Caller Review Protocol` section is gone
- `## Assumptions & Non-Issues` section (exact heading, unchanged from current file) is present
- `## Substantive Edits` section remains unchanged
- No references to the old "hard stop on any failure, restart from Pass 1" rule remain except in the updated Rationalization Table

**Step 8: Commit**

```bash
git add external/opencode/skills/run-goldfish-test/SKILL.md
git commit -m "feat: add triage framework and fix-forward re-run strategy to run-goldfish-test skill"
```

---

### Task 2: Rewrite `goldfish-test.md` command

**Files:**
- Modify: `external/opencode/commands/goldfish-test.md`

**Step 1: Read the current file**

Read `external/opencode/commands/goldfish-test.md`.

**Step 2: Replace the entire file content**

The current file inlines its own orchestration protocol. Replace it entirely with:

```markdown
---
name: goldfish-test
description: Run the three-pass Goldfish quality gate on an artifact before saving it. Accepts a file path or inline draft. Issues ✅ Goldfish Certified on success.
arguments:
  - name: artifact
    description: Path to the artifact file, or inline draft content
    required: true
---

Run the Goldfish quality gate on: {{artifact}}

Load the run-goldfish-test skill. Follow its complete protocol: prepare the artifact,
dispatch fresh-context evaluator subagents for each pass, apply triage adjudication
between passes, and issue the verdict.
```

**Step 3: Verify the file**

Read the updated file. Confirm:
- Frontmatter is intact (name, description, argument)
- No inlined phase descriptions remain
- `Load the run-goldfish-test skill` instruction is present
- File is under 20 lines

**Step 4: Commit**

```bash
git add external/opencode/commands/goldfish-test.md
git commit -m "refactor: slim goldfish-test command to delegate to run-goldfish-test skill"
```

---

### Task 3: Update `build-feature.md` goldfish gate

**Files:**
- Modify: `external/opencode/commands/build-feature.md`

**Step 1: Read the current file**

Read `external/opencode/commands/build-feature.md`.

**Step 2: Replace the `### Goldfish Gate (design doc)` section**

Locate the section beginning `### Goldfish Gate (design doc)` through the line ending `Save the certified design doc to \`docs/plans/YYYY-MM-DD-<topic>-design.md\` and commit.`

Replace with:

```markdown
### Quality Gate (design doc)

If the run-goldfish-test skill is available, load it and run the three-pass goldfish
quality gate on the draft artifact before saving. Follow the skill's triage decision
framework and re-run strategy.

The orchestrator dispatches fresh-context evaluator subagents for each pass and
adjudicates findings between passes per the skill's protocol.

If the run-goldfish-test skill is not available, present the draft to the user for
review and explicit approval before saving.

When certified (or approved), save the design doc to
`docs/plans/YYYY-MM-DD-<topic>-design.md` and commit.
```

**Step 3: Verify the file**

Read the updated file. Confirm:
- `### Quality Gate (design doc)` heading replaces `### Goldfish Gate (design doc)`
- No inlined pass descriptions remain in the gate section ("inlined" means per-pass logic, pass prompts, or step-by-step orchestration instructions; high-level delegation language such as "load the skill and follow its protocol" is acceptable)
- Conditional skill-loading is present
- Fallback path is present
- All other phases (1–5) are unchanged

**Step 4: Commit**

```bash
git add external/opencode/commands/build-feature.md
git commit -m "refactor: replace inline goldfish gate in build-feature with thin conditional phase"
```

---

### Task 4: Update `write-plan.md` goldfish gate

**Files:**
- Modify: `external/opencode/commands/write-plan.md`

**Step 1: Read the current file**

Read `external/opencode/commands/write-plan.md`.

**Step 2: Replace the `## Goldfish Gate` section**

Locate the section beginning `## Goldfish Gate` through the line ending `When all three passes complete without a hard stop: issue the certified verdict.`

Replace with:

```markdown
## Quality Gate

If the run-goldfish-test skill is available, load it and run the three-pass goldfish
quality gate on the draft artifact before saving. Follow the skill's triage decision
framework and re-run strategy.

The orchestrator dispatches fresh-context evaluator subagents for each pass and
adjudicates findings between passes per the skill's protocol.

If the run-goldfish-test skill is not available, present the draft to the user for
review and explicit approval before saving.
```

**Step 3: Verify the file**

Read the updated file. Confirm:
- `## Quality Gate` heading replaces `## Goldfish Gate`
- No inlined pass descriptions remain ("inlined" means per-pass logic, pass prompts, or step-by-step orchestration instructions; high-level delegation language such as "load the skill and follow its protocol" is acceptable)
- Conditional skill-loading is present
- Fallback path is present
- `## Save and Execute` section is unchanged

**Step 4: Commit**

```bash
git add external/opencode/commands/write-plan.md
git commit -m "refactor: replace inline goldfish gate in write-plan with thin conditional phase"
```

---

### Task 5: Verify live runtime reflects the changes

**Step 1: Confirm skill content**

Read `~/.config/opencode/skills/run-goldfish-test/SKILL.md`. Confirm `## Triage Decision Framework` is present and `## Caller Review Protocol` is absent.

**Step 2: Confirm commands**

Read `~/.config/opencode/commands/goldfish-test.md`. Confirm it is the thin wrapper (under 20 lines, no inlined phases).

Read `~/.config/opencode/commands/build-feature.md`. Confirm the `### Quality Gate (design doc)` section is present and no inlined pass descriptions remain.

Read `~/.config/opencode/commands/write-plan.md`. Confirm the `## Quality Gate` section is present and no inlined pass descriptions remain.

**Step 3: Confirm no remaining references to old protocol**

Search `external/opencode/skills/run-goldfish-test/SKILL.md` for `Caller Review Protocol`. Expected: zero results.

Search `external/opencode/commands/goldfish-test.md`, `build-feature.md`, and `write-plan.md` for `adjudicate each flag before stopping`. Expected: zero results.

**Step 4: No commit needed** — all changes committed in Tasks 1–4.

---

## Assumptions & Non-Issues

- **No tests for markdown files.** Skills and commands are markdown artifacts. Verification is by reading the changed files and checking for the presence/absence of specific content, not by running a test suite.
- **Symlink deployment is automatic.** `~/.config/opencode/skills/` and `~/.config/opencode/commands/` are directory symlinks to `external/opencode/`. Changes are immediately reflected without any manual deployment step.
- **Task ordering matters.** Task 1 (skill) must complete before Tasks 2–4 (commands), because commands reference the skill by name. If the skill is updated first, all commands are immediately consistent at runtime.
- **`goldfish-reviewer` skill and agent configs unchanged.** Per the design doc, these are out of scope. Do not touch them.
- **Heading rename in build-feature.** Task 3 replaces `### Goldfish Gate (design doc)` with `### Quality Gate (design doc)` — retaining the `(design doc)` disambiguator to distinguish this phase from other potential quality gates in the command. The design doc's Command Gate Phase Template uses `### Quality Gate` (without the suffix) because it is a generic template, not the exact text for this specific file. The plan's Task 3 text and its Step 3 verification checklist are authoritative; the design doc template is illustrative only.
- **Anchor text verification.** Each task's Step 1 reads the current file before any edits. Section anchors listed in Steps 2–6 of each task are confirmed against the actual file content read in Step 1. If an anchor is absent or differs, the executor stops, locates the nearest equivalent heading or paragraph by meaning, confirms it is the correct target, and proceeds with that as the edit anchor. If no equivalent can be identified, the executor reports the discrepancy before making any change.
- **Symlink deployment (runtime state).** The symlink relationship (`~/.config/opencode/` → `external/opencode/`) is live runtime state and cannot be demonstrated in the plan itself. Task 5 Step 2 reads `~/.config/opencode/commands/goldfish-test.md` as a practical check that the symlink is active. If that read fails, the deployment assumption should be investigated before concluding.
- **Pass 2 minor findings: plan text supersedes design doc.** The design doc (referenced file) contains an earlier formulation that says minor findings "arise from a passing Pass 2 only." The plan's replacement text for the skill is the authoritative version: minor findings are collected regardless of whether Pass 2 passes or fails; "minor" means non-blocking, not "only present when Pass 2 passes." The design doc text is source material; the plan's replacement text is what will be written into the skill and governs.
- **Skill availability detection.** The replacement text in Tasks 3 and 4 uses the phrase "if the run-goldfish-test skill is available." Availability is determined by the platform's standard behaviour: at session start, agents see the list of available skills in their context. If `run-goldfish-test` is not listed, it is unavailable and the fallback applies. No special detection mechanism is needed in the command text.
- **`goldfish-test.md` wrapper restatement is intentional.** The replacement text summarises the skill's protocol at outcome level ("prepare the artifact, dispatch fresh-context evaluator subagents for each pass, apply triage adjudication between passes, and issue the verdict"). This is orientation for the agent, not a duplication of protocol logic — the skill exclusively owns triage rules, pass prompts, and re-run strategy. Per the agentic component spec (O-2), commands are declarative prompts that orient the agent; the summary describes *what* will happen at a high level, while "follow its complete protocol" defers the *how* entirely to the skill. The text matches the design doc's Command Gate Phase Template verbatim and is intentional.
