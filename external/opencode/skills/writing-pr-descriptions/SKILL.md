---
name: writing-pr-descriptions
description: Use when drafting, creating, editing, or shortening pull-request bodies, including subsequent CI, test-result, and review-driven updates.
---

# Writing PR Descriptions

## Overview

**PR: intent + guarantees. Diff: implementation. Runbook: operation.**

Target ~200 words; small PRs shorter. No padding; useful review map may exceed target.

## When to Use

Use: PR bodies. Exclude: code reviews, commit messages, release notes, runbooks.

## Procedure

1. Read purpose, diff, current body, verification evidence, PR template. Honor selected template; else check `.github/PULL_REQUEST_TEMPLATE.md` + root/docs equivalents. No repository access: supplied facts only. Never invent context.
2. Template wins: keep headings/order, prompts, checklists, required markers. Map concerns below; never edit template file. No template: headings below. PR prose professional, not compressed; each fact once:

   | Section | Include |
   |---------|---------|
   | **Why** | Problem, consequence, goal. |
   | **Guarantees** | Observable behavior, scope, compatibility, limits. |
   | **Verification** | Checks, outcomes, gaps. |

3. Keep critical behavior, limits, risks inline. Link runbooks; no deployment commands, monitoring recipes, rollback steps.
4. Cut inventories, diff narration, boilerplate; review map excepted. Keep template fields; terse N/A if inapplicable. Implementation detail only for guarantees/trade-offs/review focus. Compatibility warnings once, never across headings.
5. Claims need evidence. Intent ≠ proven outcome. Checks: passed, failed, pending, blocked, not run. Tick checklist items only with evidence; unrun unchecked. Suggested commands ≠ completed checks; sample counts ≠ correctness/availability proof.
6. **Before returning or publishing any new/updated PR body: inspect exact complete candidate after last edit.**
   - Preserve repository template and required review map.
   - Keep intent, guarantees, material limits, decision-critical risks; each fact once.
   - Replace stale verification with current results and gaps. No execution history. Keep earlier evidence only if still relevant.
   - Link detailed evidence if available; never replace essential limits with links.
   - Count words. Above ~200: compress unless required template, review map, or necessary reviewer context warrants length.
   - Return/publish checked candidate only. Any later edit invalidates check, including CI-only updates.

   Keep checklist, word count, length rationale outside PR body. Return PR body only.

## Review Map

Required if either:
- PR-target merge-base diff ≥200 changed lines (additions + deletions, never net).
- Smaller diff mixes concerns whose composition guides review.

Measure before omitting. Count copied/generated/mechanical lines.
Simple-looking diff: no exemption.

Below 200: omit unless mixed-concern rule applies.
Counts unavailable: disclose gap; never assume small. Give qualitative review focus; never invent counts/percentages.

Template: appropriate existing section, e.g. What. No template: after Why, before Guarantees.

| Category | Diff (+ / − LoC) | Nature of change | Review focus |
|---|---:|---|---|
| Group purpose | Measured additions / deletions | Substantive change | Failure mode / review question |

- Only present categories: runtime/business logic, API contracts, tests, test support, config/build, docs, generated artifacts, verified mechanical changes. Terse cells; link one or two useful key files, no inventories.
- Measure PR-target merge-base diff at final head. Additions/deletions, never net. Refresh after changes; note base/head, method, exclusions.
- Assign each changed line once; reconcile textual totals. List binaries separately. Keep generated/verified mechanical churn visible; exclude from other rows.
- Mixed files: split hunks if practical; else disclose approximate dominant-purpose classification. File-level counts: inline fakes/concurrency harness under tests; only standalone helpers separate.
- Verify generated/mechanical labels; filenames ≠ unchanged behavior. Category/LoC ≠ risk/correctness. Guide review; never defend oversized PRs or replace guarantees/evidence.

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
| "Rollout steps explain risk." | State limit; link recipe. No duplicated runbook. |
| "Warning must stay inline." | Once under required Compatibility; never repeat in Summary. |
| "No zero-downtime claim." | Equivalent wording claims availability; audit Why too. |
| "Kept approved headings." | Body can drift; recheck repository template before edits. |
