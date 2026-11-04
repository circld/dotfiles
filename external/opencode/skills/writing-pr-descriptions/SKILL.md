---
name: writing-pr-descriptions
description: Use when drafting, editing, or shortening PR descriptions or pull request bodies.
---

# Writing PR Descriptions

## Overview

**PR: intent + guarantees. Diff: implementation. Runbook: operation.**

Target ~200 words; shorter small PRs. Never pad; useful review map may exceed target.

## When to Use

Use: PR bodies. Exclude: code reviews, commit messages, release notes, runbooks.

## Procedure

1. Read purpose, diff, existing body, verification evidence, PR template. Honor selected template; else check `.github/PULL_REQUEST_TEMPLATE.md` + root/docs equivalents. No repository access: supplied facts only. Never invent context.
2. Template wins: preserve headings/order, prompts, checklists, required markers. Map concerns below; never edit template file. No template: headings below. PR prose stays professional, not compressed; each fact once:

   | Section | Include |
   |---------|---------|
   | **Why** | Problem, consequence, goal. |
   | **Guarantees** | Observable behavior, scope, compatibility, limits. |
   | **Verification** | Checks, outcomes, gaps. |

3. Keep critical behavior, limits, risk inline. Link runbooks; no deployment commands, monitoring recipes, rollback steps.
4. Cut inventories, diff narration, boilerplate; review map excepted. Keep template fields; terse N/A when inapplicable. Implementation detail only for guarantees/trade-offs/review focus. Compatibility warnings once, never across headings.
5. Claims need evidence. Intent ≠ proven outcome. Checks: passed, failed, pending, blocked, not run. Tick checklists only with evidence; unrun stays unchecked. Suggested commands ≠ completed checks; sample counts ≠ correctness/availability proof.
6. Audit intent, guarantees, evidence. Return PR body only.

## Review Map

Large/mixed diffs: include compact table when composition guides review. Small, obvious changes: omit. No reliable counts: qualitative review focus; never invent counts/percentages.

Template: appropriate existing section, e.g. What. No template: after Why, before Guarantees.

| Category | Diff (+ / − LoC) | Nature of change | Review focus |
|---|---:|---|---|
| Group purpose | Measured additions / deletions | Substantive change | Failure mode / review question |

- Categories present only: runtime/business logic, API contracts, tests, test support, config/build, docs, generated artifacts, verified mechanical changes. Terse cells; link one or two key files when useful, not inventories.
- Measure PR-target merge-base diff at final head. Additions/deletions, never net. Refresh after changes; note base/head, method, exclusions.
- Assign each changed line once; reconcile textual totals. List binaries separately. Generated/verified mechanical churn visible; exclude from other rows.
- Mixed files: split hunks when practical; else disclose approximate dominant-purpose classification. File-level counts: inline fakes/concurrency harness stay under tests; only standalone helpers separate.
- Verify generated/mechanical labels; filenames ≠ unchanged behavior. Category/LoC ≠ risk/correctness. Guide review, not defend oversized PRs or replace guarantees/evidence.

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

Rewrite: changelog/runbook prose, repeated warnings, padding, unsupported certainty.

| Rationalization | Counter |
|-----------------|---------|
| "Rollout steps explain risk." | State limit; link recipe. No runbook duplication. |
| "Warning must stay inline." | Once under required Compatibility; never repeat in Summary. |
| "No zero-downtime claim." | Equivalent wording claims availability; audit Why too. |
| "Kept approved headings." | Body drifts; recheck repository template before edits. |
