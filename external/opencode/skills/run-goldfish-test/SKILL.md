---
name: run-goldfish-test
description: Use when running the three-pass goldfish quality gate on an artifact before saving it — covers artifact preparation, pass content, verdict, caller review protocol, and re-run rules. Not for acting as a per-pass reviewer.
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

**Failure handling:** Any pass failure = hard stop. Review the findings, update the
artifact if needed, then re-run all three passes from Pass 1. A revised artifact is a
new artifact — no partial credit carries over.

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

## Caller Review Protocol

Goldfish runs with zero external context on purpose. Its job is to surface issues in
the direct artifact, not to decide whether those issues are valid in the broader
problem domain.

After any pass raises a flag, review each item for:
- Validity against the broader context, including outside sources referenced by the
  artifact but not shown to Goldfish
- Priority of the feedback

Each flagged item must be adjudicated into one of three outcomes:

1. **Valid:** Update the artifact to resolve the issue.
2. **Invalid due to missing context:** Add the minimum context to the artifact when that
   context is useful enough to prevent the same issue from being raised again.
3. **Invalid non-issue:** State in the artifact that the item is a non-issue.

The goal is not to defend the artifact externally. The goal is to either improve the
artifact or leave a clear note in the artifact that prevents the same flag from
recurring in future Goldfish runs.

If adjudication causes a substantive artifact change, re-run all three passes from Pass 1.

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
