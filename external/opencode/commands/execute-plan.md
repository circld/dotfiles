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

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review

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

Load the finishing-a-development-branch skill and follow it.
