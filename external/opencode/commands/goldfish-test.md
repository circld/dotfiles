---
name: goldfish-test
description: Run the three-pass Goldfish quality gate on an artifact before saving it. Accepts a file path or inline draft. Issues ✅ Goldfish Certified on success.
arguments:
  - name: artifact
    description: Path to the artifact file, or inline draft content
    required: true
---

Run the Goldfish quality gate on: {{artifact}}

Load the run-goldfish-test skill.

## Phase 1 — Prepare

Follow the artifact preparation steps from the run-goldfish-test skill.

## Phase 2 — Run Pass 1 (Comprehension)

Dispatch the goldfish agent as a fresh subagent using the Pass 1 prompt from the
run-goldfish-test skill, with the assembled artifact content substituted in.

If the agent returns ❌: STOP. Report the failure and the flags raised. The author must
update the artifact and re-run from Pass 1.

## Phase 3 — Run Pass 2 (Critic)

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from Pass 1)
using the Pass 2 prompt from the run-goldfish-test skill.

If the agent returns ❌: STOP. Report the failure and the critical findings. The author
must update the artifact and re-run from Pass 1.

Collect minor findings. These will be printed after the final verdict.

## Phase 4 — Run Pass 3 (Readiness)

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from Passes
1–2) using the Pass 3 prompt from the run-goldfish-test skill. Select the Pass 3
question for the artifact type using the table in the skill.

If the agent returns ❌: STOP. Report the failure and the unresolvable questions. The
author must update the artifact and re-run from Pass 1.

## Phase 5 — Issue Verdict

Follow the verdict format from the run-goldfish-test skill. The artifact may now be saved.
