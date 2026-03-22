---
name: review-branch
description: Evaluate a feature branch against its stated purpose.
arguments:
  - name: branch_or_pr
    description: Branch name or PR number/URL
    required: false
---

Review the current feature branch: {{branch_or_pr}}

Load the reviewing-feature-branches skill.

1. Get the stated purpose:
   - From PR: gh pr view <number> --json title,body
   - Or ask the user directly.
2. Get the diff: git diff <base_branch>...HEAD
3. Dispatch the code-reviewer agent with:
   - The stated purpose (verbatim) as the spec
   - The full branch diff
   - Branch and base branch names
   - Evaluation criteria: objective achievement, engineering best practice, security, scope assessment
   - Required output: per-goal status, engineering issues (critical/important/minor), security issues, scope assessment, verdict (achieves purpose? ready to merge?)
4. Act on feedback:
   - Objective gaps: fix before merging
   - Engineering issues: fix critical/important
   - Security issues: fix all, no exceptions
5. Offer to post review as PR comment:
   - Write formatted review to temp file
   - Present choice: POST / EDIT / DO NOTHING
   - If POST: gh pr comment <number> --body-file <file>
   - If EDIT: open in $EDITOR, re-prompt with same choices
   - If DO NOTHING: clean up temp file
