---
name: build-feature
description: Implement a feature end-to-end, from idea exploration through to completion.
arguments:
  - name: description
    description: What to build
    required: true
---

Build the following feature: {{description}}

## Phase 1 — Clarify intent.

Load the brainstorming skill. Explore the idea with the user. Produce a validated design.

Ask: "Should I write this up as a design doc, or is the conversation sufficient?"

If yes, produce the design doc draft. Do NOT save yet.

### Goldfish Gate (design doc)

Before saving the design doc, run the three-pass goldfish quality gate.

Identify all files directly referenced in the draft design doc. Read each one. Do not
follow transitive references.

Assemble: draft design doc content + directly referenced file contents.

**Context cap check:** If the combined content would exceed what fits in a single
subagent dispatch alongside the pass prompt, stop and report:

> ❌ Goldfish gate error: combined content exceeds available context for a single pass.
> Narrow the design doc's direct references before proceeding.
> An artifact that cannot be Goldfish-tested cannot be saved.

**Pass 1 — Comprehension.** Dispatch the goldfish agent as a fresh subagent with:
- Persona: curious newcomer
- Question: "What is this trying to accomplish, and how does the surrounding system relate to it?"
- Task: summarise the design doc; flag any gaps, unclear intent, or assumptions made
- Failure condition: any explicit flag raised, or summary contains an inaccuracy
- Content: draft design doc + referenced files, inlined

If Pass 1 fails: stop. Update the draft. Re-run from Pass 1.

**Pass 2 — Critic.** Dispatch the goldfish agent as a fresh subagent (new dispatch) with:
- Persona: expert skeptic
- Question: "What did I miss? What's wrong, ambiguous, or unhandled?"
- Task: list all critical and minor findings
- Failure condition: any critical finding raised
- Content: draft design doc + referenced files, inlined

If Pass 2 fails: stop. Update the draft. Re-run from Pass 1. Collect minor findings.

**Pass 3 — Readiness.** Dispatch the goldfish agent as a fresh subagent (new dispatch) with:
- Persona: experienced practitioner
- Question: "Could you write a complete implementation plan from this?"
- Task: list every question needed to write the plan; mark each resolvable-from-doc or requires-external-knowledge
- Failure condition: any question not resolvable from the design doc alone
- Content: draft design doc + referenced files, inlined

If Pass 3 fails: stop. Update the draft. Re-run from Pass 1.

All three passes complete: issue ✅ Goldfish Certified. Print any minor findings from
Pass 2 as a numbered list. Save the certified design doc to
`docs/plans/YYYY-MM-DD-<topic>-design.md` and commit.

## Phase 2 — Assess complexity.

Based on the design, decide whether a formal plan is needed. Present your assessment and let the user decide:
- Proceed directly to implementation (simple, single-concern)
- Write a formal implementation plan first (multi-step, complex)

## Phase 3 — Plan (if requested).

Load the writing-plans skill. Produce an implementation plan. Save to docs/plans/YYYY-MM-DD-<feature-name>.md.

After saving, present execution choice:
- A. Subagent-driven (this session) — fresh subagent per task, automated two-stage review (spec then quality), fast iteration.
- B. Batch execution (this or separate session) — execute tasks in batches of 3, pause for human review between batches.

## Phase 4 — Implement.

Set up an isolated workspace if the scope warrants it (load the using-git-worktrees skill).

The task-implementer must follow TDD methodology for all production code.

### IF subagent-driven (choice A):

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review

### IF batch execution (choice B):

Load the executing-plans skill and follow it. Execute tasks in batches of 3. After each batch:

1. Show what was implemented and verification output.
2. Say "Ready for feedback." Wait for human response.
3. Apply changes if needed. Continue to next batch.

After each batch, dispatch the code-reviewer agent with the batch's changed files.

## Phase 5 — Finish.

Load the finishing-a-development-branch skill and follow it.
