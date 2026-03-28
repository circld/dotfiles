---
name: execute-plan
description: Execute a written implementation plan with review checkpoints.
arguments:
  - name: plan_path
    description: Path to the plan file
    required: true
---

Execute the implementation plan at: {{plan_path}}

## Phase 1 — Setup.

Read the plan. Review it critically — identify questions or concerns. If concerns: raise them before starting. If the user updates the plan based on feedback, re-read and review the updated plan.

If not in an isolated workspace, load the using-git-worktrees skill to set one up. Never start implementation on main/master without explicit user consent.

Track task progress throughout execution.

Present execution mode if not already chosen:
- A. Subagent-driven — fresh subagent per task, automated two-stage review.
- B. Batch — execute in batches of 3, human review between.

## Phase 2 — Execute.

The task-implementer must follow TDD methodology for all production code.

### IF subagent-driven (choice A):

For each task in the plan, sequentially (never dispatch multiple implementers in parallel):

1. Dispatch the task-implementer agent with the full task text, context from prior tasks, and project standards. Provide all context in the dispatch — do not make the implementer read the plan file.
2. If the implementer asks questions, answer them before letting it proceed.
3. When complete, dispatch the spec-reviewer agent with the task requirements and implementer's report.
4. If spec review fails, have implementer fix and re-submit. Repeat until passing.
5. If spec review passes, dispatch the code-reviewer agent with changed files (BASE_SHA..HEAD_SHA).
6. If code review has critical/important issues, have implementer fix and re-submit. Repeat until approved.
7. Mark task complete. Proceed to next task.

If an implementer fails a task, dispatch a new subagent with fix instructions. Do not fix manually in the coordinator context (prevents context pollution).

After all tasks: dispatch code-reviewer for final review of entire implementation.

### IF batch (choice B):

Load the executing-plans skill and follow it. Execute in batches of 3. After each batch:

1. Show what was implemented and verification output.
2. Say "Ready for feedback." Wait for human response.
3. Apply changes if needed. Continue to next batch.

After each batch, dispatch the code-reviewer agent with the batch's changed files.

### STOP conditions:

STOP executing immediately when:
- Hit a blocker (missing dependency, repeated test failure, unclear instruction)
- Plan has critical gaps
- You don't understand an instruction

Ask for clarification rather than guessing.

## Phase 3 — Finish.

Load the finishing-a-development-branch skill and follow it:

1. Run test suite. Do not proceed if tests fail.
2. Determine base branch.
3. Present exactly 4 options: merge locally, push and create PR, keep as-is, discard.
4. Execute user's choice.
5. Clean up worktree for options 1 and 4 only. For option 4, require typed "discard" confirmation. For option 2, keep worktree (may need it for review feedback).
