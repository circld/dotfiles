# Goldfish Orchestration Redesign

**Goal:** Make goldfish testing maintainable, automated for most things, prompt for important things, and judicious in token usage — while preserving modularity (components can be adopted independently).

**Constraints:** Designed to align with `docs/agentic-component-spec.md` (S-1, S-7, S-8, O-2, O-3, C-4). One pragmatic deviation is acknowledged: commands reference skills by name, which is a loose reading of O-1 — see Assumptions & Non-Issues.

---

## Problem Statement

Goldfish testing orchestration currently has three problems:

1. **Duplication.** The goldfish gate protocol is inlined (with variations) in `goldfish-test.md`, `build-feature.md`, and `write-plan.md`. Changes to the protocol require updating all three.
2. **Blunt resolution strategy.** All goldfish findings are treated equally — either the orchestrator resolves them silently (current `goldfish-test.md`) or stops for human input. There's no triage between minor auto-resolvable items and genuinely ambiguous ones.
3. **Wasteful re-runs.** The current rule ("any change → restart from Pass 1") costs up to 3 subagent dispatches per minor fix, even when the fix doesn't affect the artifact's meaning.

## Architecture

### Component Roles

| Component | Role | Goldfish dependency |
|---|---|---|
| `run-goldfish-test` skill | Canonical goldfish knowledge (triage rules, re-run strategy, pass definitions, prompts) | IS the goldfish knowledge |
| `goldfish-test.md` command | Standalone goldfish gate invocation | Loads skill (hard dependency, co-deployed) |
| `build-feature.md` command | End-to-end feature workflow with optional quality gate | Conditional: uses skill if available, falls back to human review |
| `write-plan.md` command | Plan authoring with optional quality gate | Conditional: uses skill if available, falls back to human review |
| `goldfish-reviewer` skill | Per-pass evaluator knowledge | Unchanged, loaded by goldfish agent |
| `goldfish.md` agent | Fresh-context artifact evaluator | Unchanged |

### Design Decisions

**Skill as optional-but-canonical knowledge.** The `run-goldfish-test` skill is the single source of truth for all goldfish protocol logic. Commands that use goldfish testing load the skill at runtime and delegate to it. Commands that can't find the skill fall back gracefully.

**Commands as thin enforcement wrappers.** Each command that gates on goldfish contains a ~10-line declarative phase that says: load the skill, follow its protocol, handle the fallback. The command ensures the gate structurally runs (it's a phase, not optional within the workflow). The skill defines what "run the gate" means.

**Modularity preserved.** Someone can adopt `build-feature` or `write-plan` without the goldfish skill installed. The gate phase degrades to "present the draft to the user for review and explicit approval before saving."

---

## Triage Decision Framework

The orchestrator processes each goldfish finding in two steps: validity classification, then triage.

### Step 1 — Validity Classification

Using its broader context (conversation history, user intent, project knowledge), the orchestrator determines whether each finding is valid. Context is valid grounds for dismissal only when that context is also available to the next consumer of the artifact — i.e., it is documented within the artifact's own scope. If the relevant context exists only in the current conversation, the procedure is: add it to the artifact first, then the finding can be resolved as invalid (missing context).

- **Valid:** The finding identifies a real gap or issue in the artifact. Proceed to Step 2.
- **Invalid (missing context):** The finding is wrong because the goldfish lacked context, and that context is now artifact-local (already documented or just added). Auto-resolve: add the minimum clarifying context to the artifact to prevent re-flagging. This context addition must be non-substantive — it must not change the artifact's meaning, only its clarity. If the required clarification would change meaning, reclassify the finding as valid and send it to Step 2.
- **Invalid (non-issue/misreading):** The finding is factually incorrect or irrelevant. Auto-resolve: add a note to the Assumptions & Non-Issues section. No other artifact change needed.

Invalid findings are always auto-resolved. They do not reach Step 2.

### Step 2 — Triage Matrix (valid findings only)

The orchestrator classifies each valid finding along two axes:

**Resolution certainty:** Is there exactly one correct fix, or are there multiple valid approaches?

**Impact scope:** Does the fix change the artifact's meaning/intent, or only its clarity (surface presentation, wording, and formatting)?

| | Single clear fix | Multiple valid approaches |
|---|---|---|
| **Clarity only** | Auto-resolve | Prompt human |
| **Changes meaning/intent** | Prompt human | Prompt human |

The matrix is the single authoritative decision procedure. The category lists below are examples within the matrix's cells, not additional rules. If an example appears to conflict with the matrix, the matrix governs.

### Auto-Resolve Examples

These are findings that land in the matrix's "single clear fix + clarity only" cell:

- **Surface corrections.** Fixing typos, formatting, or phrasing flagged by the goldfish.
- **Context additions.** Adding minimal clarifying text to prevent re-flagging.
- **Single-solution fixes.** Any valid finding with exactly one unambiguous, high-certainty resolution that does not change the artifact's meaning or intent.

### Human-Prompt Examples

These are findings that land in one of the matrix's "prompt human" cells:

- **Ambiguous resolution path.** The finding requires choosing between multiple valid approaches.
- **Scope/intent change.** The resolution would alter what the artifact is about or who it's for.
- **Insufficient context.** The finding reveals a genuine gap the orchestrator doesn't have enough context to resolve.
- **Challenged deliberate choice.** The goldfish questions something that may have been an intentional author decision, but the orchestrator can't determine whether it was deliberate.

### Orchestrator Context Advantage

The orchestrator has information the goldfish evaluator does not: full conversation history, the user's stated intent, awareness of the broader project context, and knowledge of other artifacts in the system. It uses this in both steps — to classify validity (Step 1) and to assess impact scope and resolution certainty (Step 2).

---

## Re-run Strategy

### During Initial Pass-Through (Passes 1→2→3)

When a pass fails, the orchestrator triages each finding:

1. **Auto-resolvable findings only:** Apply all auto-fixes, then continue to the next pass. Do NOT restart from Pass 1.
2. **Human-prompt findings only:** Stop, present findings to the user, wait for resolution. After user resolves: restart from Pass 1 (substantive change = new artifact).
3. **Mixed (both types in the same pass):** Apply all auto-fixes first, then stop and present the human-prompt findings to the user. The user sees the already-improved artifact. After user resolves: restart from Pass 1.

### Conditional Verification Re-run

**Pass 2 minor findings** are collected during the initial pass-through regardless of whether Pass 2 passes or fails, and are printed with the final verdict. They do not trigger re-runs or human prompts. Note: minor findings arise from a *passing* Pass 2 (Pass 2 only fails on critical findings). They are a separate output channel from the triage flow, which only applies to findings that caused a pass to fail. Minor findings from the initial cycle are printed; if the verification re-run also runs Pass 2, any new minor findings from that run replace the initial set.

After all three passes complete:

- If **any auto-resolved fixes** were applied during the pass-through: run one full verification cycle (all three passes) on the final artifact state.
- If all three passes were clean on first try (no fixes needed): skip the verification re-run and issue the verdict immediately.

### Loop Cap

To prevent infinite loops: after 2 full cycles (initial + verification) with continued failures, apply any auto-resolvable fixes from cycle 2, then stop and prompt the human regardless of triage category. Something structural is wrong if minor fixes keep cascading.

### Token Cost Savings

| Scenario | Current cost | New cost |
|---|---|---|
| 3 minor fixes across passes | 9 subagent dispatches (3 restarts × 3 passes) | 6 subagent dispatches (3 initial + 3 verification) |
| Clean first pass | 3 dispatches | 3 dispatches (same) |
| 1 human-prompted fix in Pass 2 | 6 dispatches (restart + 3 passes) | 6 dispatches (same — restart is correct here) |

---

## Command Gate Phase Template

### For multi-purpose commands (build-feature, write-plan, future commands):

```markdown
### Quality Gate

If the run-goldfish-test skill is available, load it and run the three-pass
goldfish quality gate on the draft artifact before saving. Follow the
skill's triage decision framework and re-run strategy.

The orchestrator dispatches fresh-context evaluator subagents for each pass
and adjudicates findings between passes per the skill's protocol.

If the run-goldfish-test skill is not available, present the draft to the
user for review and explicit approval before saving.
```

### For the standalone goldfish-test command:

```markdown
Load the run-goldfish-test skill. Follow its complete protocol: prepare the
artifact, dispatch fresh-context evaluator subagents for each pass, apply
triage adjudication between passes, and issue the verdict.
```

---

## Revised `run-goldfish-test` Skill Structure

```
# Run Goldfish Test

## Overview
## Artifact Preparation
## The Three Passes (table + Pass 3 by artifact type)
## Failure Conditions
## Pass Prompts (verbatim templates for Pass 1, 2, 3)
## Triage Decision Framework          ← NEW
  - Step 1: Validity classification (valid / invalid-context / invalid-misreading)
  - Step 2: Triage matrix (certainty × scope)
  - Auto-resolve examples
  - Human-prompt examples
  - Orchestrator context advantage
## Re-run Strategy                     ← REVISED
  - Fix-forward during initial pass-through
  - Conditional verification re-run
  - Loop cap
## Verdict
## Assumptions & Non-Issues Convention
## Substantive Edits
## Session Boundary
## Bootstrapping Exception
## Rationalization Table               ← UPDATED
```

### Changes from current skill:

| Section | Change |
|---|---|
| Triage Decision Framework | New section. Replaces and extends the old Caller Review Protocol. |
| Re-run Strategy | Revised. Replaces blanket "always restart from Pass 1" with fix-forward + conditional verification. |
| Caller Review Protocol | Removed as standalone section. Its three outcomes (Valid, Invalid/context, Invalid/non-issue) are now the validity classification step (Step 1) of the two-step triage process. |
| Rationalization Table | Updated to address new temptations (e.g., "this fix is minor, skip the verification re-run"). |

---

## Files Changed

| File | Action |
|---|---|
| `external/opencode/skills/run-goldfish-test/SKILL.md` | Modify: add Triage Decision Framework, revise re-run strategy, merge CRP into triage, update Rationalization Table |
| `external/opencode/commands/goldfish-test.md` | Modify: slim to "load skill + follow protocol" |
| `external/opencode/commands/build-feature.md` | Modify: replace inline goldfish gate with thin conditional phase |
| `external/opencode/commands/write-plan.md` | Modify: same as above |

## Files Unchanged

| File | Reason |
|---|---|
| `external/opencode/skills/goldfish-reviewer/SKILL.md` | Per-pass evaluator knowledge; unaffected by orchestration changes |
| `external/opencode/agents/goldfish.md` | Agent config; unaffected |
| `external/claude/agents/goldfish.md` | Claude Code agent config; unaffected |
| `## Substantive Edits` section in `run-goldfish-test` skill | This section's definition (an edit is substantive if it affects how a downstream agent interprets the artifact) is already consistent with the new clarity-vs-meaning distinction. No change needed.

---

## Assumptions & Non-Issues

- **Commands referencing skills by name (O-1).** The spec's O-1 rule says "agents are the only component that references other components by name." In this codebase, commands routinely instruct the agent to load named skills — this is the established convention across all commands. The command template is prompt text interpreted by an agent; the agent performs the actual skill loading. This is a pragmatic reading of O-1: the command doesn't invoke the skill directly, it tells the agent to do so. Note: this is an O-1 deviation only. S-8 (skills must not depend on specific platform components) is not implicated — the `run-goldfish-test` skill itself contains no references to other skills, agents, commands, or tools. It is pure knowledge.
- **Skill availability detection.** The design assumes agents can determine whether a skill is available before attempting to load it. This is the platform's standard behavior: agents see the list of available skills in their context at session start. If the skill isn't listed, it isn't available. No special detection mechanism is needed.
- **Auto-resolution quality.** The orchestrator's auto-resolutions are not themselves goldfish-tested. This is acceptable because they are minor by definition (triage matrix constraint) and validated by the conditional verification re-run.
- **Loop cap of 2.** Two full cycles is sufficient for minor fixes to stabilize. If they don't, the problem is structural and human judgment is needed regardless.
- **Goldfish reviewer skill unchanged.** The per-pass evaluator doesn't need to know about triage or re-run strategy — that's orchestrator-side logic. The evaluator just surfaces findings.
- **Artifact type detection.** The design references "Pass 3 by artifact type" in the skill structure outline. Artifact type is inferred by the orchestrator from the file path, structure, frontmatter, and content of the artifact — this logic is already defined in the current `run-goldfish-test` skill and is unchanged by this redesign.
- **Current state of existing files.** This design doc describes the current problems (duplication, blanket restart-from-Pass-1, blunt CRP) based on the actual state of `goldfish-test.md`, `build-feature.md`, and `write-plan.md` at time of authoring. The files are the ground truth; the problem statement is a summary, not a claim requiring verification here.
- **Triage matrix operationalization.** The matrix axes ("exactly one correct fix," "changes meaning/intent") are defined at design-doc level of abstraction. Precise criteria for evaluating each axis belong in the `run-goldfish-test` skill implementation, not in this design doc. An implementer writing the skill should encode specific heuristics for each axis based on these definitions.
- **Implementation plan external knowledge.** An implementer writing a plan from this design doc will need to read the current content of the files being modified (listed in Files Changed) and the full agentic-component-spec. This is standard — a design doc specifies what to change and why; the implementer brings knowledge of the current codebase. The Command Gate Phase Template section provides exact replacement text for command phrasing.
- **goldfish-test.md when skill is absent.** The `goldfish-test.md` command has a hard dependency on the `run-goldfish-test` skill because it is purpose-built for goldfish testing and co-deployed with the skill in the same dotfiles repo. No fallback is needed or defined — absent the skill, the command should not be used. This is distinct from `build-feature` and `write-plan`, which are general-purpose workflows with an optional gate.
