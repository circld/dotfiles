---
name: run-goldfish-test
description: Use when orchestrating the full goldfish quality gate — preparing an
  artifact, dispatching all three evaluation passes, applying the triage decision
  framework to any flags, and issuing the certified verdict. Not for acting as a
  per-pass evaluator.
---

# Run Goldfish Test

## Overview

A three-pass quality gate that verifies every artifact is complete enough to drive
the next step before it is saved.

**Iron Law:** No artifact is saved until it holds a ✅ Goldfish Certified verdict from
the current session. Certification is a property of a specific artifact state.

## Artifact Preparation

Before dispatching any pass:

1. **Resolve the artifact.** If given a file path, read the file. If given inline
   content, use it directly.

2. **Identify direct references.** Find all files directly referenced in the artifact
   (e.g., `@filename`, inline code paths, explicit mentions of sibling files). Read each
   one. Do not follow transitive references — only direct references in the artifact itself.

3. **Assemble inlined content.** Combine: artifact content + directly referenced file
   contents, each labelled by filename.

4. **Context cap check.** If the assembled content would exceed what fits in a single
   subagent dispatch alongside the pass prompt, stop and report:

   > ❌ Goldfish gate error: combined content exceeds available context for a single pass.
   > Narrow the artifact's direct references before proceeding.
   > An artifact that cannot be Goldfish-tested cannot be saved.

## The Three Passes

Each pass is dispatched as a fresh evaluator with zero prior context.

| Pass | Persona | Question |
|---|---|---|
| 1 — Comprehension | Curious newcomer | "What is this trying to accomplish, and how does the surrounding system relate to it?" |
| 2 — Critic | Expert skeptic | "What did I miss? What's wrong, ambiguous, or unhandled?" |
| 3 — Readiness | Experienced practitioner | "Could you produce the next artifact in the chain from this alone?" |

### Pass 3 question by artifact type

Infer the artifact type from the file path, structure, frontmatter, and content. Do not
ask the user.

| Artifact | Pass 3 question |
|---|---|
| Design doc | "Could you write a complete implementation plan from this?" |
| Plan | "Could you implement this feature on your first pass?" |
| Skill | "Could you follow this skill correctly in a live session?" |
| Agent config | "Could you write a skill or command that correctly uses this agent?" |
| Slash command | "Could you correctly invoke this command and interpret its output?" |

## Failure Conditions

| Pass | Fails when |
|---|---|
| 1 — Comprehension | Evaluator raises any explicit flag, or summary contains an inaccuracy |
| 2 — Critic | Any critical finding is raised |
| 3 — Readiness | Evaluator lists any question not resolvable from the artifact alone |

**Critical vs. minor (Pass 2):** A finding is critical if the next artifact cannot be
correctly produced without resolving it. A finding is minor if the next artifact can be
produced but may be suboptimal or ambiguous on an edge.

**Failure handling:** See Re-run Strategy below for the full protocol. The key
principles: auto-resolvable findings do not require a restart; human-prompted fixes
(substantive changes) do. A revised artifact is a new artifact — no partial credit
carries over.

**Session boundary:** If the session ends for any reason before all three passes
complete, re-run from Pass 1. A new session has no memory of prior passes.

## Pass Prompts

Use these prompts verbatim when dispatching each pass. Substitute the actual inlined
content for the placeholders.

### Pass 1 prompt

```
Persona: Curious newcomer — you are reading this artifact for the first time.
Question: What is this trying to accomplish, and how does the surrounding system relate to it?

Pass 1 task:
- Summarise what this artifact does and how it fits the surrounding system.
- Flag anything that is unclear, missing, or that required you to make an assumption.
- Do NOT fill gaps — flag them.

Failure condition: fail if you raise any explicit flag, or if your summary contains an inaccuracy.

[ARTIFACT CONTENT]
<inlined artifact content>

[REFERENCED FILES]
<inlined content of each directly referenced file, labelled by filename>
```

### Pass 2 prompt

```
Persona: Expert skeptic — you have deep domain experience and a low tolerance for ambiguity.
Question: What did I miss? What's wrong, ambiguous, or unhandled?

Pass 2 task:
- List every finding: critical and minor.
- Critical: a gap that would cause the next artifact to be incorrect.
- Minor: a gap that would cause the next artifact to be suboptimal or ambiguous on an edge.
- Do NOT dismiss findings — list them.

Failure condition: fail if any critical finding is raised.

[ARTIFACT CONTENT]
<inlined artifact content>

[REFERENCED FILES]
<inlined content of each directly referenced file, labelled by filename>
```

### Pass 3 prompt

```
Persona: Experienced practitioner — you are about to produce the next artifact in the chain.
Question: [insert Pass 3 question for artifact type]

Pass 3 task:
- List every question you would need answered to produce the next artifact.
- Mark each question: resolvable from artifact alone, or requires external knowledge.
- Do NOT answer questions with assumptions — list them.

Failure condition: fail if you list any question not resolvable from the artifact alone.

[ARTIFACT CONTENT]
<inlined artifact content>

[REFERENCED FILES]
<inlined content of each directly referenced file, labelled by filename>
```

## Triage Decision Framework

The orchestrator processes each finding that caused a pass to fail in two steps:
validity classification, then triage. Pass 2 minor findings are a separate output
channel (see Re-run Strategy) and do not enter this flow.

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

## Verdict

When all three passes complete with no failures:

> ✅ Goldfish Certified
>
> Passed: Pass 1 (Comprehension), Pass 2 (Critic), Pass 3 (Readiness)

If there are minor findings from Pass 2, print them as a numbered list:

> **Minor findings (do not block certification):**
> 1. [finding]
> 2. [finding]

The artifact may now be saved.

## Assumptions & Non-Issues

When dismissing a finding as a non-issue, record it in the artifact itself in an
`Assumptions & Non-Issues` section. Keep entries brief and specific.

Example format:

```markdown
## Assumptions & Non-Issues

- **Retry handling:** Retries are owned by the caller outside this artifact.
- **Config validity:** Inputs referenced here are pre-validated before this workflow begins.
```

## Substantive Edits

An edit is **substantive** if it would affect how a downstream agent interprets or acts
on the artifact. Formatting corrections and typo fixes do not require re-certification.
Any substantive edit invalidates the current certification — re-run all three passes
before saving.

## Bootstrapping

The initial creation of the goldfish skills and goldfish agent is exempt from the gate —
these artifacts cannot self-certify before they exist. Their first quality check is the
RED phase of the skill-writing workflow. All subsequent edits are gated normally.

## Rationalization Table

| Temptation | Rebuttal |
|---|---|
| "I wrote this carefully, Pass 1 is obviously fine" | The Elephant always thinks its doc is clear. That's why we have a Goldfish. |
| "The critic only found minor things, good enough" | Minor findings compound. Five minor gaps produce a broken next artifact. |
| "We're time-pressured, skip to Pass 3" | Pass 3 readiness depends on Pass 2 correctness. Skipping produces false confidence. |
| "The artifact barely changed, no need to re-run" | Certification is per artifact state. A revised artifact is a new artifact. |
| "Pass 2 findings are obvious, I'll fix them in the plan" | If they're obvious, fix them now. Design gaps fixed at plan stage cost more than at design stage. |
| "My session crashed after Pass 2, I'll just re-run Pass 3" | A new session has no memory. No passes have run. Re-run from Pass 1. |
| "This fix is minor, I can skip the verification re-run" | Auto-fixes accumulate. The verification re-run exists to catch coherence issues they introduce. Skip it and you may certify a broken artifact. |
| "Pass 2 only had minor findings, those are fine to ignore" | Minor findings are printed for a reason — they're non-blocking, not non-existent. Review them; the next artifact may be suboptimal if you don't. |
