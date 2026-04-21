---
name: reviewing-feature-branches
description: Use when evaluating a feature branch against its PR description or stated purpose, before merge or as a final review checkpoint
---

# Reviewing Feature Branches

Evaluate whether a feature branch achieves its stated purpose.

## Core Principle

A branch that doesn't achieve its stated objective is not ready to merge, regardless of code quality. Purpose-achievement outranks engineering polish.

## When to Use

- Before merging a feature branch
- When verifying a branch delivers on its PR description or requirements
- As a final review checkpoint after implementation is complete

**Not for:**
- Per-task code review during iterative development
- Per-task review during plan execution
- Reviewing individual commits mid-implementation

## Evaluation Dimensions

**1. Objective Achievement and Scope**
Map each stated goal to concrete changes. Identify goals with no implementation, implementation that contradicts stated goals, and partially implemented goals. Flag scope creep: significant work serving no stated objective. Flag missing scope: stated objectives with no corresponding implementation.

**2. Engineering Quality**
DRY violations, intention-revealing names and structure, dead code, error handling, separation of concerns, test quality (tests verify behavior, not just exercise code), consistency with existing codebase patterns.

**3. Security**
Hardcoded secrets or credentials, unvalidated user input, untrusted dependencies, authorization/authentication gaps, information leakage, injection vectors.

## Deduplication Rule

If a previously raised issues set is provided in context, apply it during evaluation across all three dimensions. Flag a finding unless you are confident it was already raised. When in doubt, flag it.

## Triage Rules

| Category | Action |
|---|---|
| Objective/scope gaps | Block merge — branch doesn't do what it says |
| Security issues | Block merge — no exceptions |
| Engineering critical/important | Fix before merge |
| Engineering minor | Note for follow-up, does not block |

## Verdict Criteria

A branch is **ready to merge** when:
- Every stated objective has corresponding implementation
- No unresolved critical or important engineering issues
- No security gaps
- Scope creep, if any, is acknowledged and justified

**Note on prior feedback:** The verdict reflects the actual state of the branch, not only new findings. A branch that still has unresolved previously-raised issues is not ready to merge even if this review pass produces no new findings.

## Output

Write the review result to a JSON file, then post it:

```bash
post-feature-branch-review.sh --review-json review.json
```

**All fields must be strings** — never arrays, booleans, or objects. Multi-line strings use `\n` for newlines within the JSON value.

| Field | Type | Notes |
|---|---|---|
| `verdict` | string | Short phrase: `"Approved"`, `"Partially"`, `"Blocked"` |
| `ready_to_merge` | string | Short phrase: `"Yes"`, `"No"`, `"With fixes"` — never a boolean |
| `reasoning` | string | 1–3 sentences explaining the verdict |
| `objective_assessment` | string | Markdown: one bullet per stated goal with Status and Evidence |
| `engineering_issues` | string | Markdown with three headings: `#### Critical (Must Fix Before Merge)`, `#### Important (Should Fix Before Merge)`, `#### Minor (Nice to Have)` |
| `security_issues` | string | Markdown list, or `"None."` if none found |
| `scope_assessment` | string | Markdown: `**Scope creep:**` and `**Missing from scope:**` lines |

**When prior feedback was provided:** If all findings in a section are already covered by previously-raised issues, write `"No new issues. All findings were previously raised."` rather than `"None."` for that section's field.

**Example:**

```json
{
  "verdict": "Partially",
  "ready_to_merge": "With fixes",
  "reasoning": "The branch mostly meets the stated purpose but leaves one path unhandled.",
  "objective_assessment": "- **Goal:** Post the automated review to GitHub\n- **Status:** Achieved\n- **Evidence:** `scripts/post-feature-branch-review.sh` renders the template.\n- **Gap:** None.",
  "engineering_issues": "#### Critical (Must Fix Before Merge)\nNone.\n\n#### Important (Should Fix Before Merge)\nNone.\n\n#### Minor (Nice to Have)\nNone.",
  "security_issues": "None.",
  "scope_assessment": "**Scope creep:** None\n**Missing from scope:** None"
}
```
