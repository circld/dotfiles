---
name: doc-review
description: Review document blockers; shared context, independent critiques,
  one repair, focused verification. Bounded finish.
arguments:
  - name: target
    description: Document path; optional --critics M (positive integer, default 2)
    required: true
---

Review document: $ARGUMENTS

Parse quoted path + optional --critics M. Missing path → request before dispatch.
Reject unknown flags, nonpositive/noninteger M.

Load run-doc-review. Orchestrator gathers shared context once; no discovery
agent. Use doc-critic for `discovery` and fresh `verify`; doc-updater for repair.
Follow skill contracts/budget; report Clean or Blocked. Default max four calls.
