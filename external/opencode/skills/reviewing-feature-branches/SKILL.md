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
- Reviewing individual commits mid-implementation

## Evaluation Dimensions

**1. Objective Achievement**
Map each stated goal to concrete changes. Identify goals with no implementation, implementation that contradicts stated goals, partially implemented goals, and scope creep (significant work serving no stated objective).

**2. Engineering Quality**
DRY violations, intention-revealing names and structure, dead code, error handling, separation of concerns, test quality (tests verify behavior, not just exercise code), consistency with existing codebase patterns.

**3. Security**
Hardcoded secrets or credentials, unvalidated user input, untrusted dependencies, authorization/authentication gaps, information leakage, injection vectors.

**4. Scope**
Work that serves no stated objective (scope creep). Stated objectives with no corresponding implementation (missing scope).

## Triage Rules

| Category | Action |
|---|---|
| Objective gaps | Block merge — branch doesn't do what it says |
| Security issues | Block merge — no exceptions |
| Engineering critical/important | Fix before merge |
| Engineering minor | Note for follow-up, does not block |

## Verdict Criteria

A branch is **ready to merge** when:
- Every stated objective has corresponding implementation
- No unresolved critical or important engineering issues
- No security gaps
- Scope creep, if any, is acknowledged and justified
