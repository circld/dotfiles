---
name: writing-pr-descriptions
description: Use when drafting, editing, or shortening PR descriptions or pull request bodies.
---

# Writing PR Descriptions

## Overview

**PR explains intent and guarantees; diff explains implementation; runbook explains operation.**

Target ~200 words; small changes shorter. Never pad.

## When to Use

Use: PR bodies. Exclude: code reviews, commit messages, release notes, runbooks.

## Procedure

1. Before drafting/editing, read purpose, diff, existing description, verification evidence, applicable PR template. Honor selected template; otherwise check `.github/PULL_REQUEST_TEMPLATE.md` and root/docs equivalents. No repository access: supplied facts only. Never invent context.
2. Template controls structure: preserve headings/order, prompts, checklists, required markers. Map concerns below into template; never edit template file. No template: use default headings below. Normal professional prose; each fact once:

   | Section | Include |
   |---------|---------|
   | **Why** | Problem, consequence, intended outcome. |
   | **Guarantees** | Observable behavior, scope, compatibility, important limits. |
   | **Verification** | Relevant checks, outcomes, meaningful gaps. |

3. Critical behavior changes, limits, risk context inline. Runbooks linked; no deployment commands, monitoring recipes, rollback steps.
4. Cut file/function inventories, diff narration, boilerplate. Keep template fields; concise N/A if inapplicable. Implementation detail only for guarantees/trade-offs. Never repeat compatibility warnings across headings.
5. Evidence bounds claims. Intent ≠ proven outcome. Checks: passed, failed, pending, blocked, not run. Check checklist items only with evidence; unrun stays unchecked. Suggested commands ≠ completed checks; sample counts ≠ correctness/availability proof.
6. Review intent, guarantees, evidence. Return PR body only.

## Example

```markdown
## Why

Delayed workers can finish after a replacement worker has taken over a job,
allowing an outdated result to overwrite newer progress. This change makes
result acceptance depend on the worker's current lease rather than arrival
order, so replacing a stalled worker does not expose its successor to stale
writes.

## Guarantees

- A result is accepted only while its worker holds the current lease for that
  job. Results from replaced workers are rejected.
- Jobs remain independent: replacing a worker for one job does not invalidate
  another job's lease. Existing result response fields are preserved.
- This guards result storage, not external side effects. Work already sent to
  another service can still happen more than once.

Lease recovery and operator procedures: [runbook](docs/worker-leases.md).

## Verification

- Lease regression tests: 12 passed, covering replacement, late results, and
  isolation between jobs.
- Existing response-contract tests: passed.
- Multi-region failover was not exercised; these checks establish local lease
  behavior, not cross-region availability.
```

## Mistakes / Red Flags

Rewrite: changelog/runbook prose, repeated warnings, quota padding, unsupported certainty.

| Rationalization | Counter |
|-----------------|---------|
| "Rollout steps explain risk." | State limit; link recipe. No duplicate runbook. |
| "Warning must stay inline." | Once under required Compatibility; never repeat in Summary. |
| "No zero-downtime claim." | Equivalent wording still claims availability; audit Why too. |
| "Kept approved headings." | Existing body can drift; recheck repository template before edits. |
