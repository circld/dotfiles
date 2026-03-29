---
name: address-pr-reviews
description: Process PR review comments — fix issues, reply to threads, mark resolved.
arguments:
  - name: pr_reference
    description: PR number or URL
    required: true
---

Address review comments on PR: {{pr_reference}}

Requires: file write, shell execution, git access.

Load the address-pr-reviews skill and follow it.

For each unresolved review thread:
1. Classify as actionable or out-of-scope.
2. If actionable, implement the fix.
3. Reply to the thread explaining what was done.
4. Mark the thread as resolved.

Do not modify code outside the scope of the PR diff.
