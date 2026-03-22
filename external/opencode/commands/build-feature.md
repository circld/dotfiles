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

Ask: "Should I write this up as a design doc, or is the conversation sufficient?" If yes, write to docs/plans/YYYY-MM-DD-<topic>-design.md and commit.

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

For each task in the plan, sequentially (never dispatch multiple implementers in parallel):

1. Dispatch the task-implementer agent with the full task text, context from prior tasks, and project standards. Provide all context in the dispatch — do not make the implementer read the plan file.
2. If the implementer asks questions, answer them before letting it proceed.
3. When implementation is complete, dispatch the spec-reviewer agent with the task requirements and the implementer's report. The spec-reviewer verifies by reading code, not trusting the report.
4. If spec review fails, have the implementer fix issues and re-submit to spec-reviewer. Repeat until passing.
5. If spec review passes, dispatch the code-reviewer agent with the changed files (BASE_SHA..HEAD_SHA) and project standards.
6. If code review has critical/important issues, have the implementer fix them and re-submit to code-reviewer. Repeat until approved.
7. Mark task complete. Proceed to next task.

If an implementer fails a task, dispatch a new subagent with fix instructions. Do not fix manually in the coordinator context (prevents context pollution).

After all tasks: dispatch code-reviewer for a final review of the entire implementation.

### IF batch execution (choice B):

Load the executing-plans skill and follow it. Execute tasks in batches of 3. After each batch:

1. Show what was implemented and verification output.
2. Say "Ready for feedback." Wait for human response.
3. Apply changes if needed. Continue to next batch.

After each batch, dispatch the code-reviewer agent with the batch's changed files.

## Phase 5 — Finish.

Load the finishing-a-development-branch skill and follow it:

1. Run test suite. Do not proceed if tests fail.
2. Determine base branch.
3. Present exactly 4 options: merge locally, push and create PR, keep as-is, discard.
4. Execute user's choice.
5. Clean up worktree for options 1 and 4 only. For option 4, require typed "discard" confirmation. For option 2, keep worktree (may need it for review feedback).
