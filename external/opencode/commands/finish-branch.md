---
name: finish-branch
description: Wrap up development work — verify, integrate, and clean up.
arguments: []
---

Wrap up the current development work.

Load the finishing-a-development-branch skill and follow it.

1. Run test suite. Do not proceed if tests fail.
2. Determine base branch: git merge-base HEAD main, fallback to master, or ask.
3. Present exactly 4 options:
   1. Merge back to <base-branch> locally
   2. Push and create a Pull Request
   3. Keep the branch as-is
   4. Discard this work
4. Execute user's choice:
   - Option 1: checkout base, pull, merge, verify tests on merged result, delete feature branch, clean up worktree.
   - Option 2: push with -u, create PR via gh pr create. Keep worktree (user may need it for review feedback).
   - Option 3: report branch and worktree location. Done.
   - Option 4: confirm with typed "discard". Checkout base, force-delete branch, clean up worktree.
5. Worktree cleanup: Options 1 and 4 only.
