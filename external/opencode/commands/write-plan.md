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

Load the run-goldfish-test skill.

Follow the artifact preparation steps from the skill using the draft plan.

**Pass 1 — Comprehension.** Dispatch the goldfish agent as a fresh subagent using the
Pass 1 prompt from the run-goldfish-test skill.

If Pass 1 fails: stop. Update the draft. Re-run from Pass 1.

**Pass 2 — Critic.** Dispatch the goldfish agent as a fresh subagent (new dispatch)
using the Pass 2 prompt from the run-goldfish-test skill.

If Pass 2 fails: stop. Update the draft. Re-run from Pass 1. Collect minor findings.

**Pass 3 — Readiness.** Dispatch the goldfish agent as a fresh subagent (new dispatch)
using the Pass 3 prompt from the run-goldfish-test skill. The artifact type is plan —
use the corresponding Pass 3 question from the skill.

If Pass 3 fails: stop. Update the draft. Re-run from Pass 1.

All three passes complete: follow the verdict format from the run-goldfish-test skill.

## Save and Execute

Save the certified plan to `docs/plans/YYYY-MM-DD-<feature-name>.md`.

Present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
