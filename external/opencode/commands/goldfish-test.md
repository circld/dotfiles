---
name: goldfish-test
description: Run the three-pass Goldfish quality gate on an artifact before saving it. Accepts a file path or inline draft. Issues ✅ Goldfish Certified on success.
arguments:
  - name: artifact
    description: Path to the artifact file, or inline draft content
    required: true
---

Run the Goldfish quality gate on: {{artifact}}

## Phase 1 — Prepare

Prepare the artifact: resolve the file path or inline content, read all directly
referenced files, and assemble the inlined content. If the assembled content
exceeds what fits in a single subagent dispatch alongside a pass prompt, stop and
report the context cap error — the artifact must narrow its direct references before
the gate can proceed.

## Phase 2 — Run Pass 1 (Comprehension)

Dispatch the goldfish agent as a fresh subagent with the assembled artifact content.
The evaluator's persona is a curious newcomer; the question is what the artifact is
trying to accomplish and how the surrounding system relates to it.

If the agent returns ❌: adjudicate each flag before stopping. Flags that are
non-issues or resolvable by adding context to the artifact must be resolved inline —
do not stop for these. Hard-stop only on valid flags that genuinely require author
input. If the artifact is updated substantively, re-run from Pass 1.

## Phase 3 — Run Pass 2 (Critic)

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from
Pass 1). The evaluator's persona is an expert skeptic; the question is what is
wrong, ambiguous, or unhandled.

If the agent returns ❌: adjudicate each flag before stopping. Flags that are
non-issues or resolvable by adding context to the artifact must be resolved inline —
do not stop for these. Hard-stop only on valid flags that genuinely require author
input. If the artifact is updated substantively, re-run from Pass 1.

Collect minor findings. These will be printed after the final verdict.

## Phase 4 — Run Pass 3 (Readiness)

Dispatch the goldfish agent as a fresh subagent (new dispatch, zero context from
Passes 1–2). The evaluator's persona is an experienced practitioner; the question
is whether they could produce the next artifact in the chain from this alone. Select
the appropriate Pass 3 question for the artifact type.

If the agent returns ❌: adjudicate each flag before stopping. Flags that are
non-issues or resolvable by adding context to the artifact must be resolved inline —
do not stop for these. Hard-stop only on valid flags that genuinely require author
input. If the artifact is updated substantively, re-run from Pass 1.

## Phase 5 — Issue Verdict

All three passes complete without a hard stop:

> ✅ Goldfish Certified
>
> Passed: Pass 1 (Comprehension), Pass 2 (Critic), Pass 3 (Readiness)

If there are minor findings from Pass 2, print them as a numbered list after the
verdict. The artifact may now be saved.
