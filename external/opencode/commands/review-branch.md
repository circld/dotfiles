---
name: review-branch
description: Evaluate a feature branch against its stated purpose.
arguments:
  - name: branch_or_pr
    description: Branch name or PR number/URL
    required: false
---

Review the current feature branch: {{branch_or_pr}}

Load the reviewing-feature-branches skill for evaluation criteria and triage rules.

1. Get the stated purpose:
   - From PR: gh pr view <number> --json title,body
   - Or ask the user directly.
2. Get the diff: git diff <base_branch>...HEAD
3. Dispatch the code-reviewer agent with:
   - The stated purpose (verbatim) as the spec
   - The full branch diff
   - Branch and base branch names
   - The skill's evaluation dimensions as the review criteria
   - Required output: per-goal status, engineering issues (critical/important/minor),
     security issues, scope assessment, verdict (achieves purpose? ready to merge?)
4. Apply the skill's triage rules to the review results.
5. Post review to PR (optional):
   - Write review data as JSON to a temp file (fields: verdict, ready_to_merge,
     reasoning, objective_assessment, engineering_issues, security_issues,
     scope_assessment)
   - Run the post-feature-branch-review script
   - Use --pr <number> when auto-detect is unavailable
   - Use --dry-run to preview without posting
   - Use --edit to open in $EDITOR before posting
   - Present choice: POST / EDIT / DO NOTHING
   - Clean up the JSON temp file after posting or cancellation
   - If no PR exists, ask the user or skip posting
