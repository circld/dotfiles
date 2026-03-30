---
name: write-plan
description: Produce an implementation plan from a spec or requirements.
arguments:
  - name: description
    description: What to plan
    required: true
---

Write an implementation plan for: {{description}}

If not already in an isolated workspace and the scope warrants it, load the using-git-worktrees skill to set one up.

Load the writing-plans skill and follow it. Save plan to docs/plans/YYYY-MM-DD-<feature-name>.md.

After saving, present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
