---
name: reviewing-feature-branches
description: Use when evaluating a feature branch against its PR description or stated purpose, before merge or as a final review checkpoint
---

# Reviewing Feature Branches

Dispatch a code-reviewer subagent to evaluate whether a feature branch achieves its stated purpose.

**Core principle:** A branch that doesn't achieve its stated objective is not ready to merge, regardless of code quality.

## When to Use

- Before merging a feature branch
- When a PR description exists and you need to verify the branch delivers on it
- As a final review checkpoint after implementation is complete
- When asked to review a branch, PR, or set of changes against requirements

**Not this skill:**
- Reviewing code quality during iterative development (use requesting-code-review)
- Reviewing individual commits mid-implementation (use requesting-code-review)

## How to Review

**1. Get the PR description / stated purpose:**

From a PR URL:
```bash
gh pr view <PR_NUMBER> --json title,body --jq '.title + "\n\n" + .body'
```

Or from the user directly.

**2. Get the diff against base branch:**
```bash
BASE_BRANCH=$(gh pr view <PR_NUMBER> --json baseRefName --jq '.baseRefName')
git diff ${BASE_BRANCH}...HEAD
```

**3. Dispatch feature-branch-reviewer subagent:**

Use Task tool with `code-reviewer` type, fill template at `feature-branch-reviewer.md`.

**Placeholders:**
- `{PURPOSE}` - The PR description or stated purpose (verbatim)
- `{BASE_BRANCH}` - The base branch (e.g., main)
- `{FEATURE_BRANCH}` - The feature branch name
- `{DESCRIPTION}` - Brief summary of the branch

**4. Act on feedback:**
- **Objective gaps** - Fix before merging; the branch doesn't do what it says
- **Engineering issues** - Fix critical/important; note minor for follow-up
- **Security issues** - Fix all before merging; no exceptions

## Integration

**Complements:**
- **requesting-code-review** - General code quality during development
- **finishing-a-development-branch** - Use this skill as part of the finishing workflow

**Subagent template:** See `feature-branch-reviewer.md`
