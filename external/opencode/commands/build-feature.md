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

Before saving the design doc, run the three-pass goldfish quality gate. Prepare the
artifact, then dispatch the goldfish agent as a fresh subagent for each pass with
zero prior context. The artifact type is design doc.

If any pass raises flags: adjudicate each flag before stopping. Flags that are
non-issues or resolvable by adding context to the artifact must be resolved inline —
do not stop for these. Hard-stop only on valid flags that genuinely require author
input. If the artifact is updated substantively, re-run from Pass 1.

When all three passes complete without a hard stop: issue the certified verdict.
Save the certified design doc to `docs/plans/YYYY-MM-DD-<topic>-design.md` and commit.

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
