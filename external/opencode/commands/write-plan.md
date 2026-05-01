---
name: write-plan
description: Produce an implementation plan from a spec or requirements.
arguments:
  - name: description
    description: What to plan
    required: true
---

Write an implementation plan for: {{description}}

If not already in an isolated workspace and the scope warrants it, load the
using-git-worktrees skill to set one up.

Load the writing-plans skill and follow it. Produce a draft plan. Do NOT save yet.

## Quality Gate

If the run-goldfish-test skill is available, load it and run the three-pass goldfish
quality gate on the draft artifact before saving. Follow the skill's triage decision
framework and re-run strategy.

The orchestrator dispatches fresh-context evaluator subagents for each pass and
adjudicates findings between passes per the skill's protocol.

If the run-goldfish-test skill is not available, present the draft to the user for
review and explicit approval before saving. If not approved, revise the draft based
on feedback and repeat until explicit approval.

## Save and Execute

Save the certified or approved plan to `docs/plans/YYYY-MM-DD-<feature-name>.md`.

Present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
