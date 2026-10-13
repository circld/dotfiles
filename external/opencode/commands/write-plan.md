---
name: write-plan
description: Produce an implementation plan from a spec or requirements.
arguments:
  - name: description
    description: What to plan
    required: true
---

Write an implementation plan for: $ARGUMENTS

If not already in an isolated workspace and the scope warrants it, load the
using-git-worktrees skill to set one up.

Load the writing-plans skill and follow it. Produce a draft plan. Do NOT save yet.

Present the draft to the user for review and explicit approval before saving. If not approved, revise the
draft based on feedback and repeat until explicit approval.

## Save and Execute

Save the clean or approved plan to `docs/plans/YYYY-MM-DD-<feature-name>.md`.

Present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
