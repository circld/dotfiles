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

## Goldfish Gate

Before saving the plan, run the three-pass goldfish quality gate on the draft.
Prepare the artifact, then dispatch the goldfish agent as a fresh subagent for each
pass with zero prior context. The artifact type is plan.

If any pass raises flags: adjudicate each flag before stopping. Flags that are
non-issues or resolvable by adding context to the artifact must be resolved inline —
do not stop for these. Hard-stop only on valid flags that genuinely require author
input. If the artifact is updated substantively, re-run from Pass 1.

When all three passes complete without a hard stop: issue the certified verdict.

## Save and Execute

Save the certified plan to `docs/plans/YYYY-MM-DD-<feature-name>.md`.

Present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
