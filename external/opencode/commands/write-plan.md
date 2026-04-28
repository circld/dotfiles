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

Identify all files directly referenced in the draft plan. Read each one. Do not follow
transitive references.

Assemble: draft plan content + directly referenced file contents.

**Context cap check:** If the combined content would exceed what fits in a single
subagent dispatch alongside the pass prompt, stop and report:

> ❌ Goldfish gate error: combined content exceeds available context for a single pass.
> Narrow the plan's direct references before proceeding.
> An artifact that cannot be Goldfish-tested cannot be saved.

**Pass 1 — Comprehension.** Dispatch the goldfish agent as a fresh subagent with:
- Persona: curious newcomer
- Question: "What is this trying to accomplish, and how does the surrounding system relate to it?"
- Task: summarise the plan; flag any gaps, unclear steps, or assumptions made
- Failure condition: any explicit flag raised, or summary contains an inaccuracy
- Content: draft plan + referenced files, inlined

If Pass 1 fails: stop. Update the draft. Re-run from Pass 1.

**Pass 2 — Critic.** Dispatch the goldfish agent as a fresh subagent (new dispatch) with:
- Persona: expert skeptic
- Question: "What did I miss? What's wrong, ambiguous, or unhandled?"
- Task: list all critical and minor findings
- Failure condition: any critical finding raised
- Content: draft plan + referenced files, inlined

If Pass 2 fails: stop. Update the draft. Re-run from Pass 1. Collect minor findings.

**Pass 3 — Readiness.** Dispatch the goldfish agent as a fresh subagent (new dispatch) with:
- Persona: experienced practitioner
- Question: "Could you implement this feature on your first pass?"
- Task: list every question needed to implement; mark each resolvable-from-plan or requires-external-knowledge
- Failure condition: any question not resolvable from the plan alone
- Content: draft plan + referenced files, inlined

If Pass 3 fails: stop. Update the draft. Re-run from Pass 1.

All three passes complete: issue ✅ Goldfish Certified. Print any minor findings from
Pass 2 as a numbered list.

## Save and Execute

Save the certified plan to `docs/plans/YYYY-MM-DD-<feature-name>.md`.

Present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
