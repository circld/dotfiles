# Design: Address Branch Review Feedback

Addresses feedback from reviewing `refactor-agentic-ai-components` against its stated purpose. The review identified 1 critical, 4 important, and 3 minor issues across the branch's 35 changed files.

This design covers tasks 1-2 (the reviewing-feature-branches skill and review-branch command). The remaining tasks are independent fixes that don't require a design.

## Problem

The `reviewing-feature-branches` skill is not a skill per the agentic-component-spec taxonomy. It contains orchestration (sequenced steps 1-5), tool references (`gh`, `git`, `post-feature-branch-review.sh`), a broken reference to a deleted template (`feature-branch-reviewer.md`), and prompt placeholders (`{PURPOSE}`, `{BASE_BRANCH}`). Per the spec, it is functioning as a command.

A `review-branch` command already exists and duplicates the skill's orchestration. The skill adds no unique domain knowledge beyond what the command and `code-reviewer` agent already cover — except that the evaluation dimensions, triage rules, and verdict criteria are domain knowledge worth preserving as a reusable skill.

The `build-feature` and `execute-plan` commands were considered as consumers of this skill, but their review operates at the per-task level (not branch level), so they keep their inline triage rules. The shared dispatch protocol between those two commands is a separate problem (task #9).

## Design

### Skill: reviewing-feature-branches

Rewrite `SKILL.md` as pure domain knowledge. Remove all orchestration, tool references, bash snippets, and template references.

Content:

- **Core principle:** Purpose-achievement outranks engineering polish. A branch that doesn't achieve its stated objective is not ready to merge regardless of code quality.
- **When to use / not for:** Branch-level review before merge. Not for per-task review during implementation.
- **Evaluation dimensions:**
  1. Objective achievement — map goals to changes, identify gaps and scope creep
  2. Engineering quality — DRY, naming, dead code, error handling, separation of concerns, test quality, codebase consistency
  3. Security — secrets, input validation, dependencies, auth, info leakage, injection
  4. Scope — scope creep (unrelated work) and missing scope (unimplemented objectives)
- **Triage rules:** Table mapping category to action (objective gaps and security block merge; critical/important fix before merge; minor note for follow-up)
- **Verdict criteria:** Ready to merge when all objectives implemented, no unresolved critical/important issues, no security gaps

Target: ~45 lines. No references to tools, agents, other skills, commands, templates, or scripts.

Supporting files in the directory are unchanged:

- `pr-comment-template.md` — stays as-is
- `scripts/post-feature-branch-review.sh` — stays at current location, tightly coupled to this skill's template and output schema
- `tests/` — stays, fixtures updated separately (task #3)

### Command: review-branch

Update to delegate domain knowledge to the skill. Keep all orchestration.

Changes:

- Step 3: Reference "the skill's evaluation dimensions" instead of listing criteria inline
- Step 4: Replace inline triage rules with "apply the skill's triage rules"
- Step 5: Expand with full temp file lifecycle moved from the skill:
  - Write review data as JSON (fields: verdict, ready_to_merge, reasoning, objective_assessment, engineering_issues, security_issues, scope_assessment)
  - Run the post-feature-branch-review script (agent resolves path; per C-4, command describes what to do, not exact paths)
  - Flags: `--pr`, `--dry-run`, `--edit`
  - Present choice: POST / EDIT / DO NOTHING
  - Clean up JSON temp file after posting or cancellation
  - If no PR exists, ask user or skip

### What does NOT change

- `build-feature.md` and `execute-plan.md` — per-task triage stays inline (branch-level skill doesn't apply to task-level review)
- `code-reviewer` agent definition — already correct
- `pr-comment-template.md` — already updated
- `post-feature-branch-review.sh` — no moves, no changes

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Skill content | Pure domain knowledge (evaluation criteria, triage, verdict) | Per S-4, S-8, O-3: skills are leaf nodes with no tool/agent/component references |
| Deleted template | Not restored; content already in code-reviewer agent | Avoids duplication; agent owns the review prompt, skill owns evaluation criteria |
| Script location | Stays in skill directory | Tightly coupled to skill's template and output schema; not reusable |
| Command references script | By name, not path | Per C-4: declarative templates; agent resolves location |
| build-feature/execute-plan triage | Unchanged | Branch-level skill doesn't apply to per-task review; separate problem (task #9) |
| Temp file lifecycle | Owned by command | Skill loses orchestration; command is the orchestrator; script handles its own rendered file cleanup |

## Related Tasks

All review feedback items tracked as tasks:

1. Rewrite reviewing-feature-branches skill as pure domain knowledge (this design)
2. Update review-branch command to delegate domain knowledge to skill (this design)
3. Update stale test fixtures (OpenCode reference)
4. Rewrite subagent-driven-development flowchart labels to domain actions
5. Fix debug.md: inconsistent skill loading pattern
6. Remove inline duplication in finish-branch.md
7. Clean up informal metadata in agentic-component-spec.md
8. Add agent routing to address-pr-reviews.md per C-3
9. Extract shared dispatch protocol from build-feature/execute-plan (separate design needed)
