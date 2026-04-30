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

Load the run-goldfish-test skill.

Follow the artifact preparation steps from the skill using the draft design doc.

**Pass 1 — Comprehension.** Dispatch the goldfish agent as a fresh subagent using the
Pass 1 prompt from the run-goldfish-test skill.

If Pass 1 fails: stop. Update the draft. Re-run from Pass 1.

**Pass 2 — Critic.** Dispatch the goldfish agent as a fresh subagent (new dispatch)
using the Pass 2 prompt from the run-goldfish-test skill.

If Pass 2 fails: stop. Update the draft. Re-run from Pass 1. Collect minor findings.

**Pass 3 — Readiness.** Dispatch the goldfish agent as a fresh subagent (new dispatch)
using the Pass 3 prompt from the run-goldfish-test skill. The artifact type is design
doc — use the corresponding Pass 3 question from the skill.

If Pass 3 fails: stop. Update the draft. Re-run from Pass 1.

All three passes complete: follow the verdict format from the run-goldfish-test skill.
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
