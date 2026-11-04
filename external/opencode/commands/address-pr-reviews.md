---
name: address-pr-reviews
description: Process PR review comments — fix issues, reply to threads, mark resolved.
arguments:
  - name: pr_reference
    description: PR number or URL
    required: true
---

Address review comments on PR: $ARGUMENTS

Requires: file write, shell execution, git access.

Load the address-pr-reviews skill and follow it.

Present only open, actionable items in plain language: what, why, effort, and cost/risk if skipped. Ask which items to address before making changes.

For each selected item:
1. Implement the fix and show what changed.
2. Get explicit approval to commit and push to the PR branch.
3. Commit, push, and verify the remote PR branch contains the fix commit.
4. Reply with the commit link, then resolve inline threads only; top-level feedback gets a reply only. If push is declined, fails, or cannot be verified, do not claim "Fixed" or resolve.

Do not modify code outside the scope of the PR diff.
