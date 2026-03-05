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

**5. Post review to PR (optional):**

After presenting the review and acting on feedback, offer to post it as a PR comment.

Auto-detect PR:
```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
```

If `gh pr view` fails (no PR for current branch), ask the user for a PR number or URL. If no PR exists, skip posting.

Confirm target: "Post review to PR #$PR_NUMBER?"

Format the subagent's review output into the collapsible comment structure defined in `pr-comment-template.md`. Map the subagent's output sections to template placeholders:
- Verdict's "Does this branch achieve its stated purpose?" value -> `{VERDICT}`
- Verdict's "Ready to merge?" value -> `{READY_TO_MERGE}`
- Verdict's "Reasoning:" text -> `{VERDICT_REASONING}`
- Full Objective Assessment section -> `{OBJECTIVE_ASSESSMENT}`
- Full Engineering Issues section -> `{ENGINEERING_ISSUES}`
- Full Security Issues section -> `{SECURITY_ISSUES}`
- Full Scope Assessment section -> `{SCOPE_ASSESSMENT}`

Write the formatted comment to a temp file:
```bash
REVIEW_FILE=$(mktemp /tmp/pr-review-XXXX.md)
```

Present choice to user: **POST** / **EDIT** / **DO NOTHING**

- **POST**: Submit the comment.
  ```bash
  gh pr comment $PR_NUMBER --body-file "$REVIEW_FILE"
  rm "$REVIEW_FILE"
  ```
- **EDIT**: Open in `$EDITOR` for modifications, then re-prompt with the same 3 choices.
  ```bash
  ${EDITOR:-vim} "$REVIEW_FILE"
  ```
- **DO NOTHING**: Skip posting, clean up.
  ```bash
  rm "$REVIEW_FILE"
  ```

## Integration

**Complements:**
- **requesting-code-review** - General code quality during development
- **finishing-a-development-branch** - Use this skill as part of the finishing workflow

**Subagent template:** See `feature-branch-reviewer.md`
