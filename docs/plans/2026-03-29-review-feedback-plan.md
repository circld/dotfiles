# Address Branch Review Feedback — Implementation Plan

**Goal:** Fix all issues identified in the branch review of `refactor-agentic-ai-components`, excluding the shared dispatch protocol extraction (task #9, separate design needed).

**Architecture:** Eight independent edits to existing files. Tasks 1-3 implement the design doc (skill rewrite + command update + test cleanup). Tasks 4-8 are standalone fixes. No new files created.

**Tech Stack:** Markdown, Bash (test fixtures)

**Design doc:** `docs/plans/2026-03-29-review-feedback-design.md`

---

### Task 1: Rewrite reviewing-feature-branches skill as pure domain knowledge

**Files:**
- Modify: `external/opencode/skills/reviewing-feature-branches/SKILL.md` (replace lines 7-83)

**Step 1: Read the current skill and the design doc**

Read `external/opencode/skills/reviewing-feature-branches/SKILL.md` and `docs/plans/2026-03-29-review-feedback-design.md` to confirm the target content.

**Step 2: Replace the skill body**

Replace everything after the YAML frontmatter with:

```markdown
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
```

Keep the YAML frontmatter (lines 1-4) unchanged.

**Step 3: Verify the skill has no tool, agent, or component references**

Search the rewritten file for: `gh `, `git `, `scripts/`, `feature-branch-reviewer`, `code-reviewer`, `post-feature-branch-review`, backtick-wrapped bash blocks. None should be present.

**Step 4: Verify line count**

Confirm the file is under 50 lines (excluding frontmatter). Target: ~45 lines.

**Step 5: Commit**

```bash
git add external/opencode/skills/reviewing-feature-branches/SKILL.md
git commit -m "rewrite reviewing-feature-branches as pure domain knowledge

Remove orchestration, tool references, bash snippets, and broken
template reference. Keep evaluation dimensions, triage rules, verdict
criteria. Per S-4, S-8, O-3."
```

---

### Task 2: Delete test-skill-posting-instructions.sh

**Files:**
- Delete: `external/opencode/skills/reviewing-feature-branches/tests/test-skill-posting-instructions.sh`

**Step 1: Confirm the test validates content that no longer exists**

Read `test-skill-posting-instructions.sh`. It validates the skill's step 5 (posting section) which was removed in Task 1. The test greps for `scripts/post-feature-branch-review.sh`, JSON fields, and flag documentation — all removed from the skill.

**Step 2: Delete the test**

```bash
git rm external/opencode/skills/reviewing-feature-branches/tests/test-skill-posting-instructions.sh
```

**Step 3: Run remaining tests to confirm they still pass**

```bash
for f in external/opencode/skills/reviewing-feature-branches/tests/test-post-feature-branch-review-*.sh; do
  bash "$f"
done
```

All `test-post-feature-branch-review-*.sh` tests validate the script, not the skill. They should pass unchanged.

**Step 4: Commit**

```bash
git add -A external/opencode/skills/reviewing-feature-branches/tests/
git commit -m "delete test-skill-posting-instructions.sh

Test validated skill posting section content that was removed in the
skill rewrite. Script tests (test-post-feature-branch-review-*.sh)
are unaffected."
```

---

### Task 3: Update review-branch command

**Files:**
- Modify: `external/opencode/commands/review-branch.md` (full rewrite of body)

**Step 1: Read the current command**

Read `external/opencode/commands/review-branch.md`.

**Step 2: Rewrite the command body**

Replace everything after the frontmatter with:

```markdown
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
```

**Step 3: Verify the command references the skill for domain knowledge**

Confirm steps 3-4 reference "the skill's evaluation dimensions" and "the skill's triage rules" rather than inlining criteria.

**Step 4: Verify step 5 includes temp file lifecycle**

Confirm step 5 mentions: creating the JSON, running the script, cleanup after posting/cancellation.

**Step 5: Commit**

```bash
git add external/opencode/commands/review-branch.md
git commit -m "update review-branch command: delegate domain knowledge to skill

Inline evaluation criteria and triage rules replaced with references
to reviewing-feature-branches skill. Step 5 expanded with full temp
file lifecycle (moved from skill)."
```

---

### Task 4: Update stale test fixtures

**Files:**
- Modify: `external/opencode/skills/reviewing-feature-branches/tests/fixtures/expected-comment.md:3`
- Modify: `external/opencode/skills/reviewing-feature-branches/tests/fixtures/expected-comment-edited.md:3`

**Step 1: Read both fixture files and the template**

Read `expected-comment.md`, `expected-comment-edited.md`, and `pr-comment-template.md`. Confirm the template says `> Automated review against PR description.` (no "by OpenCode").

**Step 2: Update expected-comment.md line 3**

Change:
```
> Automated review by OpenCode against PR description.
```
To:
```
> Automated review against PR description.
```

**Step 3: Update expected-comment-edited.md line 3**

Same change as Step 2.

**Step 4: Run the tests that use these fixtures**

```bash
bash external/opencode/skills/reviewing-feature-branches/tests/test-post-feature-branch-review-render.sh
bash external/opencode/skills/reviewing-feature-branches/tests/test-post-feature-branch-review-post.sh
```

Expected: PASS (fixtures now match template).

**Step 5: Commit**

```bash
git add external/opencode/skills/reviewing-feature-branches/tests/fixtures/
git commit -m "fix test fixtures: remove stale OpenCode reference

Update expected-comment.md and expected-comment-edited.md to match
pr-comment-template.md (\"Automated review against PR description\")."
```

---

### Task 5: Rewrite subagent-driven-development flowchart labels

**Files:**
- Modify: `external/opencode/skills/subagent-driven-development/SKILL.md:40-83`

**Step 1: Read the flowchart section**

Read `external/opencode/skills/subagent-driven-development/SKILL.md` lines 40-83.

**Step 2: Replace agent-role labels with domain-action labels**

In the `process` digraph (lines 40-83), replace node labels:

| Old label | New label |
|---|---|
| `"Dispatch implementer subagent"` | `"Implement task"` |
| `"Implementer subagent asks questions?"` | `"Questions before starting?"` |
| `"Answer questions, provide context"` | `"Answer questions, provide context"` (unchanged) |
| `"Implementer subagent implements, tests, commits, self-reviews"` | `"Implement, test, commit, self-review"` |
| `"Dispatch spec reviewer subagent"` | `"Verify spec compliance"` |
| `"Spec reviewer subagent confirms code matches spec?"` | `"Code matches spec?"` |
| `"Implementer subagent fixes spec gaps"` | `"Fix spec gaps"` |
| `"Dispatch code quality reviewer subagent"` | `"Review code quality"` |
| `"Code quality reviewer subagent approves?"` | `"Code quality approved?"` |
| `"Implementer subagent fixes quality issues"` | `"Fix quality issues"` |
| `"Dispatch final code reviewer subagent for entire implementation"` | `"Final code quality review of entire implementation"` |

Also update the edge references that use these labels as source/target node IDs.

**Step 3: Verify no node labels contain "subagent", "Dispatch", or "reviewer subagent"**

Search the modified flowchart for these terms. None should appear in node labels. (The word "subagent" may still appear in the skill's prose — that's fine, it describes the execution model.)

**Step 4: Verify the flowchart is valid dot syntax**

Visually confirm all edge references match their updated node label strings exactly.

**Step 5: Commit**

```bash
git add external/opencode/skills/subagent-driven-development/SKILL.md
git commit -m "rewrite flowchart labels as domain actions

Replace agent-role labels (Dispatch implementer subagent) with
domain actions (Implement task). Per S-8, S-4: skills describe
what to do, not which actors to dispatch."
```

---

### Task 6: Fix debug.md command pattern

**Files:**
- Modify: `external/opencode/commands/debug.md:14`

**Step 1: Read the current command**

Read `external/opencode/commands/debug.md`.

**Step 2: Replace the skill-loading directive**

Change line 14 from:
```
When creating a failing test case (Phase 4), follow TDD methodology — load the test-driven-development skill.
```
To:
```
When creating a failing test case (Phase 4), follow TDD methodology.
```

Rationale: The systematic-debugging skill already loaded in line 12 describes Phase 4. The command shouldn't also load a second skill directly — the agent decides whether TDD guidance is needed. The instruction to "follow TDD methodology" is a domain-level action (per C-4).

**Step 3: Commit**

```bash
git add external/opencode/commands/debug.md
git commit -m "fix debug.md: remove direct skill loading

Replace explicit skill load with domain-level action. Per C-4:
commands describe what to accomplish, not which skills to load."
```

---

### Task 7: Remove inline duplication in finish-branch.md

**Files:**
- Modify: `external/opencode/commands/finish-branch.md` (lines 11-23)

**Step 1: Read the command and the skill it loads**

Read `external/opencode/commands/finish-branch.md` and `external/opencode/skills/finishing-a-development-branch/SKILL.md`. Confirm steps 1-5 in the command are duplicated from the skill.

**Step 2: Compare the command steps to the skill**

Verify each command step maps to a skill step:
- Command step 1 (run tests) = Skill Step 1
- Command step 2 (determine base) = Skill Step 2
- Command step 3 (present 4 options) = Skill Step 3
- Command step 4 (execute choice) = Skill Step 4
- Command step 5 (worktree cleanup) = Skill Step 5

**Step 3: Remove the duplicated steps**

Replace the command body (after frontmatter) with:

```markdown
Wrap up the current development work.

Load the finishing-a-development-branch skill and follow it.
```

The skill already covers every step. The command adds no orchestration beyond loading the skill — it's a simple routing command (like `brainstorm.md` and `write-plan.md`).

**Step 4: Commit**

```bash
git add external/opencode/commands/finish-branch.md
git commit -m "remove inline duplication in finish-branch.md

Steps 1-5 were duplicated verbatim from the skill. Command now
loads the skill and follows it, like other simple routing commands."
```

---

### Task 8: Clean up informal metadata in agentic-component-spec.md

**Files:**
- Modify: `docs/agentic-component-spec.md:248-256`

**Step 1: Read the end of the spec**

Read `docs/agentic-component-spec.md` lines 245-256.

**Step 2: Remove the informal sections**

Delete lines 248-256 (the `Source:` attribution and `## related ideas` section with YAML-like tags). These are personal note-taking metadata that don't belong in a specification document.

**Step 3: Verify the file ends cleanly after the Quick Reference table**

The last content line should be the final row of the Quick Reference table (`| V-9 | ...`), followed by a single trailing newline.

**Step 4: Commit**

```bash
git add docs/agentic-component-spec.md
git commit -m "remove informal metadata from agentic-component-spec.md

Delete source attribution and related-ideas tags. Personal
note-taking metadata doesn't belong in a specification."
```

---

### Task 9: Add agent routing to address-pr-reviews.md

**Files:**
- Modify: `external/opencode/commands/address-pr-reviews.md`

**Step 1: Read the current command**

Read `external/opencode/commands/address-pr-reviews.md`. Note it requires write access (implements fixes) and git operations (commits) but doesn't specify an agent.

**Step 2: Assess what agent routing means here**

Per C-3: "If a command requires file writes, route it to an agent with write access." In the current setup, the primary agent executes commands — there's no separate write-capable agent to route to. The fix is to document the capability requirements, not to route to a nonexistent agent.

Add after the description in the frontmatter:

```yaml
capabilities:
  - file-write
  - shell-execute
  - git
```

If the platform doesn't support a `capabilities` field in command frontmatter, instead add a note at the top of the command body:

```markdown
Requires: file write, shell execution, git access.
```

**Step 3: Commit**

```bash
git add external/opencode/commands/address-pr-reviews.md
git commit -m "document capability requirements in address-pr-reviews.md

Per C-3: commands requiring specific capabilities should declare
them. This command needs file write, shell, and git access."
```
