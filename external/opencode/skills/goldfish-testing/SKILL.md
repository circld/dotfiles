---
name: goldfish-testing
description: Use when evaluating any artifact (design doc, plan, skill, agent config, slash command) before saving it — runs a three-pass quality gate to verify the artifact is complete enough to produce the next artifact in the chain. Load when acting as a goldfish reviewer for any pass.
---

# Goldfish Testing

## Overview

A three-pass quality gate that verifies every artifact is complete enough to drive
the next step before it is saved.

**Iron Law:** No artifact is saved until it holds a ✅ Goldfish Certified verdict from
the current session. Certification is a property of a specific artifact state.

## The Three Passes

Each pass is run by a fresh evaluator with zero prior context.

| Pass | Persona | Question |
|---|---|---|
| 1 — Comprehension | Curious newcomer | "What is this trying to accomplish, and how does the surrounding system relate to it?" |
| 2 — Critic | Expert skeptic | "What did I miss? What's wrong, ambiguous, or unhandled?" |
| 3 — Readiness | Experienced practitioner | "Could you produce the next artifact in the chain from this alone?" |

### Pass 3 question by artifact type

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

**Failure handling:** Any pass failure = hard stop. The caller reviews the findings,
updates the artifact if needed, then re-runs all three passes from Pass 1. A revised
artifact is a new artifact — no partial credit carries over.

**Session boundary:** If the session ends for any reason before all three passes
complete, re-run from Pass 1. A new session has no memory of prior passes.

**Minor findings:** Printed to session as a numbered list after the ✅ verdict. Do not
block certification. The author decides what to do with them.

## Meta-Principle

In all three passes, surface problems rather than resolve them silently.

- Pass 1: flag gaps rather than filling them
- Pass 2: list findings rather than dismissing them
- Pass 3: list open questions rather than answering them with assumptions

Producing a cleaner output by hiding uncertainty is the failure mode this gate is
designed to catch.

## Agent Input Contract

Each pass receives:
- The artifact content, inlined in full

No prior pass outputs are shared. The evaluator receives nothing beyond the direct
artifact the orchestrator explicitly passes. Referenced files, surrounding documents,
and broader system context are intentionally excluded.

If the inlined artifact would exceed the context available for a single pass dispatch,
the gate errors. An artifact that cannot be evaluated in a single pass dispatch cannot
be saved.

## Caller Review Protocol

Goldfish runs with zero external context on purpose. Its job is to surface issues in
the direct artifact, not to decide whether those issues are valid in the broader
problem domain.

After any pass raises a flag, the caller reviews each item for:
- Validity against the broader context, including outside sources referenced by the
  artifact but not shown to Goldfish
- Priority of the feedback

Each flagged item must be adjudicated into one of three outcomes:

1. **Valid:** Update the artifact to resolve the issue.
2. **Invalid due to missing context:** Add the minimum context to the artifact when that
   context is useful enough to prevent the same issue from being raised again.
3. **Invalid non-issue:** State in the artifact that the item is a non-issue. Use this
   outcome whenever the caller decides not to add more context.

The goal is not to defend the artifact externally. The goal is to either improve the
artifact or leave a clear note in the artifact that prevents the same flag from
recurring in future Goldfish runs.

If adjudication causes a substantive artifact change, re-run all three passes from Pass
1.

## Assumptions & Non-Issues

When the caller dismisses a finding as a non-issue, record it in the artifact itself in
an `Assumptions & Non-Issues` section. Keep entries brief and specific so a future
Goldfish pass can see why the issue does not apply.

Example format:

```markdown
## Assumptions & Non-Issues

- **Retry handling:** Retries are owned by the caller outside this artifact.
- **Config validity:** Inputs referenced here are pre-validated before this workflow
  begins.
```

## Substantive Edits

An edit is **substantive** if it would affect how a downstream agent interprets or acts
on the artifact. Formatting corrections and typo fixes do not require re-certification.
Any substantive edit invalidates the current certification — the artifact must be re-run
through all three passes before saving.

## Bootstrapping

The initial creation of the goldfish skill and goldfish agent is exempt from the gate —
these artifacts cannot self-certify before they exist. Their first quality check is the
RED phase of the skill-writing workflow (dispatching an evaluator without the skill to
verify baseline behaviour). All subsequent edits to those files are gated normally as
substantive edits.

## Rationalization Table

| Temptation | Rebuttal |
|---|---|
| "I wrote this carefully, Pass 1 is obviously fine" | The Elephant always thinks its doc is clear. That's why we have a Goldfish. |
| "The critic only found minor things, good enough" | Minor findings compound. Five minor gaps produce a broken next artifact. |
| "We're time-pressured, skip to Pass 3" | Pass 3 readiness depends on Pass 2 correctness. Skipping produces false confidence. |
| "The artifact barely changed, no need to re-run" | Certification is per artifact state. A revised artifact is a new artifact. |
| "Pass 2 findings are obvious, I'll fix them in the plan" | If they're obvious, fix them now. Design gaps fixed at plan stage cost more than at design stage. |
| "My session crashed after Pass 2, I'll just re-run Pass 3" | A new session has no memory. No passes have run. Re-run from Pass 1. |
