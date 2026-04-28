---
name: goldfish-test
description: Run the three-pass Goldfish quality gate on an artifact before saving it. Accepts a file path or inline draft. Issues ✅ Goldfish Certified on success.
arguments:
  - name: artifact
    description: Path to the artifact file, or inline draft content
    required: true
---

Run the Goldfish quality gate on: {{artifact}}

## Phase 1 — Prepare

Resolve the artifact:
- If {{artifact}} is a file path, read the file.
- If {{artifact}} is inline content, use it directly.

Identify all files directly referenced in the artifact (e.g., `@filename`, inline code
paths, explicit mentions of sibling files). Read each referenced file. Do not follow
transitive references — only direct references in the artifact itself.

Assemble the full inlined content: artifact + all directly referenced files.

**Context cap check:** If assembling the artifact plus all referenced file contents
would exceed what can fit in a single subagent dispatch alongside the pass prompt, STOP.
Report:

> ❌ Goldfish gate error: combined content exceeds available context for a single pass.
> Narrow the artifact's direct references before proceeding.
> An artifact that cannot be Goldfish-tested cannot be saved.

## Phase 2 — Run Pass 1 (Comprehension)

Dispatch the goldfish agent as a fresh subagent with the following prompt (substitute
the actual inlined content for the placeholders):

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

If the agent returns ❌: STOP. Report the failure and the flags raised. Do not proceed
to Pass 2. The author must update the artifact and re-run from Pass 1.

## Phase 3 — Run Pass 2 (Critic)

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from Pass 1)
with the following prompt:

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

If the agent returns ❌: STOP. Report the failure and the critical findings. Do not
proceed to Pass 3. The author must update the artifact and re-run from Pass 1.

Collect minor findings. These will be printed after the final verdict.

## Phase 4 — Run Pass 3 (Readiness)

Determine the artifact type by reading the artifact content and inferring from context
(file path, structure, frontmatter, content). Use judgment — do not ask the user.
Select the appropriate Pass 3 question from the table:

| Artifact type | Pass 3 question |
|---|---|
| Design doc | Could you write a complete implementation plan from this? |
| Plan | Could you implement this feature on your first pass? |
| Skill | Could you follow this skill correctly in a live session? |
| Agent config | Could you write a skill or command that correctly uses this agent? |
| Slash command | Could you correctly invoke this command and interpret its output? |

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from Passes
1–2) with the following prompt:

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

If the agent returns ❌: STOP. Report the failure and the unresolvable questions. The
author must update the artifact and re-run from Pass 1.

## Phase 5 — Issue Verdict

All three passes complete with no failures.

Report:

> ✅ Goldfish Certified
>
> Passed: Pass 1 (Comprehension), Pass 2 (Critic), Pass 3 (Readiness)

If there are minor findings from Pass 2, print them as a numbered list:

> **Minor findings (do not block certification):**
> 1. [finding]
> 2. [finding]
> ...

The artifact may now be saved.
