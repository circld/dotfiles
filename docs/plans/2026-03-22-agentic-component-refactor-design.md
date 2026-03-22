# Agentic Component Refactor Design

**Goal:** Refactor all agentic AI components to adhere to the agentic component spec (`260320_agentic-component-spec.md`) and be fully client/provider agnostic.

**Architecture:** Extract orchestration from skills into commands and agent definitions. Skills become pure knowledge units. Commands own workflow sequencing. Agents are reusable capabilities dispatched with context by commands. All components use plain markdown, no client-specific markup.

**Spec:** `260320_agentic-component-spec.md`

---

## Design Decisions

1. **Skills are pure knowledge units (O-3).** No skill references another skill, agent, tool, or command by name. Skills describe domain-level actions only (S-4, S-8).

2. **Commands own orchestration.** Multi-phase workflow sequencing lives in command templates. Commands reference skills (by loading intent) and agents (by dispatch) — this is permitted because the agent executing the command resolves the references (O-1).

3. **Agents are reusable capabilities.** Agent definitions encode identity, methodology, and output format. Workflow-specific delegation context (what to review, against what, scope) is provided by the command template at dispatch time (O-4).

4. **Client-neutral agent definitions (option C).** Agent markdown files are shared as-is across OpenCode and Claude Code. Both consume markdown with YAML frontmatter. Client-specific concerns (model routing, tool restrictions) live in each client's config (`work-opencode.json`, Claude Code settings), not in the agent file.

5. **Plain markdown descriptions.** No `<example>`/`<commentary>` XML tags. Agent and skill descriptions use natural language with markdown examples.

6. **`build-feature` is adaptive.** After brainstorming, the agent assesses complexity and the user decides whether to write a formal plan or proceed directly to implementation. No mandatory ceremony for simple tasks.

7. **Brainstorming triggers aggressively.** Low activation threshold — invoke for any task where intent, scope, or approach is not fully obvious. Unnecessary clarification is better than building the wrong thing.

8. **`verification-before-completion` activates automatically.** Its trigger condition is aggressive enough that the agent loads it whenever about to claim completion. No command needs to explicitly orchestrate it.

9. **Remove CLAUDE.md "Skills Usage" directive.** The directive "Use skills as process frameworks for complex tasks, not as gatekeepers for every action" was a patch for coupling between skills. The refactor fixes the root cause.

10. **`writing-skills` references the agentic component spec.** Post-refactor, the `writing-skills` skill uses `260320_agentic-component-spec.md` as the authoritative source for skill authoring rules (S-1 through S-8, plus relevant orchestration and verification rules). This replaces ad-hoc guidance and ensures future skills conform to the spec.

---

## Component Inventory

### Skills (12, all pure knowledge units)

| Skill | Description (post-refactor trigger condition) |
|---|---|
| `brainstorming` | Use when the user requests new functionality, changes to existing behavior, or any task where the intent, scope, or approach is not fully obvious. Err on the side of invoking. Not for purely mechanical tasks like renaming, reformatting, or running commands. |
| `writing-plans` | Use when you have a spec, design, or requirements for a multi-step task, before touching code. |
| `executing-plans` | Use when you have a written implementation plan to execute with batch-based human review checkpoints. |
| `using-git-worktrees` | Use when starting feature work that needs isolation from the current workspace. |
| `finishing-a-development-branch` | Use when implementation is complete and you need to decide how to integrate the work. |
| `test-driven-development` | Use when implementing any feature or bugfix, before writing implementation code. |
| `systematic-debugging` | Use when encountering any bug, test failure, or unexpected behavior, before proposing fixes. |
| `subagent-driven-development` | Use when executing implementation plans with independent tasks using per-task subagent dispatch in the current session. |
| `reviewing-feature-branches` | Use when evaluating a feature branch against its PR description or stated purpose, before merge or as a final review checkpoint. |
| `address-pr-reviews` | Use when addressing PR review comments — fixing issues, replying to threads, marking resolved. |
| `writing-skills` | Use when creating new skills, editing existing skills, or verifying skills work before deployment. |
| `verification-before-completion` | Use when about to claim work is complete, fixed, or passing, before committing or creating PRs. Evidence before assertions, always. |

**Removed:** `requesting-code-review` — absorbed into `code-reviewer` agent definition and command orchestration.

### Agents (3)

#### `code-reviewer`

**Delegation contract:** Given changed files and a reference standard (plan, spec, PR description, or project coding standards), return a structured review with categorized issues.

**Description:** Use this agent to review code for quality, architecture, and adherence to project standards. It returns categorized issues (critical, important, suggestions) with actionable recommendations.

Example: A feature implementation is complete and needs review before merging. Dispatch this agent with the changed files and project coding standards.

**System prompt content (reusable identity):**
- Plan alignment analysis: compare implementation against reference standard, identify deviations
- Code quality assessment: patterns, error handling, type safety, naming, maintainability
- Architecture and design review: SOLID, separation of concerns, integration, scalability
- Test quality: verify behavior not mocks, edge cases, coverage
- Security: hardcoded secrets, input validation, injection vectors, auth gaps
- Documentation and standards: adherence to project conventions
- Issue categorization: Critical (must fix), Important (should fix), Suggestions (nice to have)
- Output format: Strengths, Issues (by severity with file:line), Recommendations, Verdict
- Communication: acknowledge what was done well before highlighting issues

**Does not include:** workflow-specific context (what to review, against what). That is provided by the dispatching command.

#### `spec-reviewer`

**Delegation contract:** Given a specification and an implementation, verify the implementation matches the spec. Return pass/fail with specific deviations.

**Description:** Use this agent to verify that an implementation matches its specification. It returns pass/fail with specific deviations. Use for task-level or branch-level spec compliance checks.

Example: A task from an implementation plan has been completed. Dispatch this agent with the task spec and changed files to verify compliance.

**System prompt content (reusable identity):**
- CRITICAL: Do not trust the implementer's report. Verify everything independently by reading code.
- DO NOT: take their word, trust claims about completeness, accept their interpretation of requirements
- DO: read actual code, compare to requirements line by line, check for missing pieces, look for extras
- Check for: missing requirements, extra/unneeded work, misunderstandings
- Output format: pass/fail verdict with specific deviations (missing, extra, misunderstood) with file:line references

#### `task-implementer`

**Delegation contract:** Given a single task description, relevant context, and project standards, produce a working implementation with tests and a summary of changes.

**Description:** Use this agent to implement a single bounded task from a plan. It receives a task description, relevant context, and project standards, and produces a working implementation following TDD methodology.

Example: An implementation plan has 8 tasks. Dispatch this agent for each task with the task description and dependencies from prior tasks.

**System prompt content (reusable identity):**
- Before beginning: ask questions about requirements, approach, dependencies, anything unclear. Raise concerns before starting work.
- While working: if encountering something unexpected or unclear, ask questions. Don't guess.
- Implementation: follow TDD methodology for all production code
- Self-review before reporting: completeness (all requirements?), quality (clean, well-named?), discipline (YAGNI, existing patterns?), testing (behavior not mocks?)
- Report format: what was implemented, what was tested and results, files changed, self-review findings, issues or concerns

### Commands (9)

#### `build-feature`

```yaml
---
name: build-feature
description: Implement a feature end-to-end, from idea exploration through to completion.
arguments:
  - name: description
    description: What to build
    required: true
---
```

```markdown
Build the following feature: {{description}}

## Phase 1 — Clarify intent.

Load the brainstorming skill. Explore the idea with the user. Produce a validated design.

Ask: "Should I write this up as a design doc, or is the conversation sufficient?" If yes, write to docs/plans/YYYY-MM-DD-<topic>-design.md and commit.

## Phase 2 — Assess complexity.

Based on the design, decide whether a formal plan is needed. Present your assessment and let the user decide:
- Proceed directly to implementation (simple, single-concern)
- Write a formal implementation plan first (multi-step, complex)

## Phase 3 — Plan (if requested).

Load the writing-plans skill. Produce an implementation plan. Save to docs/plans/YYYY-MM-DD-<feature-name>.md.

After saving, present execution choice:
- A. Subagent-driven (this session) — fresh subagent per task, automated two-stage review (spec then quality), fast iteration.
- B. Batch execution (this or separate session) — execute tasks in batches of 3, pause for human review between batches.

## Phase 4 — Implement.

Set up an isolated workspace if the scope warrants it (load the using-git-worktrees skill).

The task-implementer must follow TDD methodology for all production code.

### IF subagent-driven (choice A):

For each task in the plan, sequentially (never dispatch multiple implementers in parallel):

1. Dispatch the task-implementer agent with the full task text, context from prior tasks, and project standards. Provide all context in the dispatch — do not make the implementer read the plan file.
2. If the implementer asks questions, answer them before letting it proceed.
3. When implementation is complete, dispatch the spec-reviewer agent with the task requirements and the implementer's report. The spec-reviewer verifies by reading code, not trusting the report.
4. If spec review fails, have the implementer fix issues and re-submit to spec-reviewer. Repeat until passing.
5. If spec review passes, dispatch the code-reviewer agent with the changed files (BASE_SHA..HEAD_SHA) and project standards.
6. If code review has critical/important issues, have the implementer fix them and re-submit to code-reviewer. Repeat until approved.
7. Mark task complete. Proceed to next task.

If an implementer fails a task, dispatch a new subagent with fix instructions. Do not fix manually in the coordinator context (prevents context pollution).

After all tasks: dispatch code-reviewer for a final review of the entire implementation.

### IF batch execution (choice B):

Load the executing-plans skill and follow it. Execute tasks in batches of 3. After each batch:

1. Show what was implemented and verification output.
2. Say "Ready for feedback." Wait for human response.
3. Apply changes if needed. Continue to next batch.

After each batch, dispatch the code-reviewer agent with the batch's changed files.

## Phase 5 — Finish.

Load the finishing-a-development-branch skill and follow it:

1. Run test suite. Do not proceed if tests fail.
2. Determine base branch.
3. Present exactly 4 options: merge locally, push and create PR, keep as-is, discard.
4. Execute user's choice.
5. Clean up worktree for options 1 and 4 only. For option 4, require typed "discard" confirmation. For option 2, keep worktree (may need it for review feedback).
```

#### `brainstorm`

```yaml
---
name: brainstorm
description: Explore an idea through collaborative dialogue to clarify intent and produce a validated design.
arguments:
  - name: description
    description: The idea to explore
    required: true
---
```

```markdown
Explore the following idea: {{description}}

Load the brainstorming skill and follow it. This command produces a validated design only — no implementation.

If the design is validated, ask: "Should I write this up as a design doc?" If yes, write to docs/plans/YYYY-MM-DD-<topic>-design.md and commit.
```

#### `write-plan`

```yaml
---
name: write-plan
description: Produce an implementation plan from a spec or requirements.
arguments:
  - name: description
    description: What to plan
    required: true
---
```

```markdown
Write an implementation plan for: {{description}}

If not already in an isolated workspace and the scope warrants it, load the using-git-worktrees skill to set one up.

Load the writing-plans skill and follow it. Save plan to docs/plans/YYYY-MM-DD-<feature-name>.md.

After saving, present execution choice:
- A. Subagent-driven (this session) — invoke /execute-plan
- B. Batch execution (separate session) — guide user to open new session in worktree and invoke /execute-plan
```

#### `execute-plan`

```yaml
---
name: execute-plan
description: Execute a written implementation plan with review checkpoints.
arguments:
  - name: plan_path
    description: Path to the plan file
    required: true
---
```

```markdown
Execute the implementation plan at: {{plan_path}}

## Phase 1 — Setup.

Read the plan. Review it critically — identify questions or concerns. If concerns: raise them before starting. If the user updates the plan based on feedback, re-read and review the updated plan.

If not in an isolated workspace, load the using-git-worktrees skill to set one up. Never start implementation on main/master without explicit user consent.

Track task progress throughout execution.

Present execution mode if not already chosen:
- A. Subagent-driven — fresh subagent per task, automated two-stage review.
- B. Batch — execute in batches of 3, human review between.

## Phase 2 — Execute.

The task-implementer must follow TDD methodology for all production code.

### IF subagent-driven (choice A):

For each task in the plan, sequentially (never dispatch multiple implementers in parallel):

1. Dispatch the task-implementer agent with the full task text, context from prior tasks, and project standards. Provide all context in the dispatch — do not make the implementer read the plan file.
2. If the implementer asks questions, answer them before letting it proceed.
3. When complete, dispatch the spec-reviewer agent with the task requirements and implementer's report.
4. If spec review fails, have implementer fix and re-submit. Repeat until passing.
5. If spec review passes, dispatch the code-reviewer agent with changed files (BASE_SHA..HEAD_SHA).
6. If code review has critical/important issues, have implementer fix and re-submit. Repeat until approved.
7. Mark task complete. Proceed to next task.

If an implementer fails a task, dispatch a new subagent with fix instructions. Do not fix manually in the coordinator context (prevents context pollution).

After all tasks: dispatch code-reviewer for final review of entire implementation.

### IF batch (choice B):

Load the executing-plans skill and follow it. Execute in batches of 3. After each batch:

1. Show what was implemented and verification output.
2. Say "Ready for feedback." Wait for human response.
3. Apply changes if needed. Continue to next batch.

After each batch, dispatch the code-reviewer agent with the batch's changed files.

### STOP conditions:

STOP executing immediately when:
- Hit a blocker (missing dependency, repeated test failure, unclear instruction)
- Plan has critical gaps
- You don't understand an instruction

Ask for clarification rather than guessing.

## Phase 3 — Finish.

Load the finishing-a-development-branch skill and follow it:

1. Run test suite. Do not proceed if tests fail.
2. Determine base branch.
3. Present exactly 4 options: merge locally, push and create PR, keep as-is, discard.
4. Execute user's choice.
5. Clean up worktree for options 1 and 4 only. For option 4, require typed "discard" confirmation. For option 2, keep worktree (may need it for review feedback).
```

#### `debug`

```yaml
---
name: debug
description: Systematically investigate and fix a bug or unexpected behavior.
arguments:
  - name: issue
    description: Description of the bug or unexpected behavior
    required: false
---
```

```markdown
Debug the following issue: {{issue}}

Load the systematic-debugging skill and follow it. Do not propose fixes until root cause is identified.

When creating a failing test case (Phase 4), follow TDD methodology — load the test-driven-development skill.
```

#### `address-pr-reviews`

```yaml
---
name: address-pr-reviews
description: Process PR review comments — fix issues, reply to threads, mark resolved.
arguments:
  - name: pr_reference
    description: PR number or URL
    required: true
---
```

```markdown
Address review comments on PR: {{pr_reference}}

Load the address-pr-reviews skill and follow it.

For each unresolved review thread:
1. Classify as actionable or out-of-scope.
2. If actionable, implement the fix.
3. Reply to the thread explaining what was done.
4. Mark the thread as resolved.

Do not modify code outside the scope of the PR diff.
```

#### `write-skill`

```yaml
---
name: write-skill
description: Create or edit an agentic skill using TDD methodology.
arguments:
  - name: skill_name
    description: Name of the skill to create or edit
    required: true
---
```

```markdown
Create or edit a skill: {{skill_name}}

Load the writing-skills skill and follow it.

Follow the TDD cycle for skills:
1. RED — Write pressure scenarios. Dispatch a subagent WITHOUT the skill to establish baseline behavior. Document exact rationalizations and failures.
2. GREEN — Write the skill addressing those specific failures. Dispatch same scenarios WITH the skill. Verify compliance.
3. REFACTOR — Identify new loopholes. Add explicit counters. Re-test until bulletproof.

Track checklist progress throughout. Do not create multiple skills in batch — complete the full TDD cycle for each skill before starting the next.
```

#### `review-branch`

```yaml
---
name: review-branch
description: Evaluate a feature branch against its stated purpose.
arguments:
  - name: branch_or_pr
    description: Branch name or PR number/URL
    required: false
---
```

```markdown
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
```

#### `finish-branch`

```yaml
---
name: finish-branch
description: Wrap up development work — verify, integrate, and clean up.
arguments: []
---
```

```markdown
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
```

---

## Skill Refactoring Rules

Apply these transformations to each of the 12 skills:

### 1. Strip all cross-references (S-8, O-1, O-3)

Remove every mention of other skills, agents, or tools by name. Replace with domain-level action descriptions.

| Before | After |
|---|---|
| "Use superpowers:test-driven-development" | "Follow TDD methodology" |
| "Use superpowers:using-git-worktrees" | (remove — command handles this) |
| "Use superpowers:finishing-a-development-branch" | (remove — command handles this) |
| "REQUIRED SUB-SKILL: Use superpowers:executing-plans" | (remove — command handles this) |
| "Use elements-of-style:writing-clearly-and-concisely if available" | "Write the design doc clearly and concisely" |
| "dispatch code-reviewer subagent" | (remove — command handles dispatch) |
| "Use Task tool with code-reviewer type" | (remove — command handles dispatch) |
| "TodoWrite" | "Track task progress" |

### 2. Rewrite descriptions as trigger conditions (S-2, S-6)

Each description starts with "Use when..." and includes specific triggering conditions. Include "when not to use." Never summarize the skill's workflow in the description.

### 3. Front-load decision-relevant content (S-3)

Critical workflow steps and decision criteria at the top. Supplementary context and edge cases at the bottom.

### 4. Dissolve prompt templates into agents + commands

| Current location | Reusable identity → | Workflow context → |
|---|---|---|
| `subagent-driven-development/implementer-prompt.md` | `task-implementer` agent | `execute-plan` / `build-feature` command |
| `subagent-driven-development/spec-reviewer-prompt.md` | `spec-reviewer` agent | `execute-plan` / `build-feature` command |
| `subagent-driven-development/code-quality-reviewer-prompt.md` | `code-reviewer` agent | `execute-plan` / `build-feature` command |
| `requesting-code-review/code-reviewer.md` | `code-reviewer` agent | `execute-plan` / `build-feature` command |
| `reviewing-feature-branches/feature-branch-reviewer.md` | `code-reviewer` agent | `review-branch` command |

### 5. Remove Integration/Called-by/Pairs-with sections

Every skill currently has an `Integration` section listing which skills call it and which it pairs with. These sections are orchestration metadata that belongs in commands. Remove them all.

### 6. Remove plan header skill directives

The `writing-plans` skill currently embeds a directive in plan headers: "REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan." Post-refactor, plans must not reference skills. Remove this directive from the plan header template.

### 7. Rewrite writing-skills to reference the agentic component spec

The `writing-skills` skill currently has ad-hoc guidance on skill authoring (ASO, cross-referencing conventions, `superpowers:` prefix patterns). Post-refactor, replace this with a reference to `260320_agentic-component-spec.md` as the authoritative source for skill rules. Specifically:

- Replace the "Cross-Referencing Other Skills" section with guidance that skills must not reference other components by name (S-8)
- Replace ad-hoc description guidance with the spec's S-2 (write description for the router) and S-6 (include when to use and when not to use)
- Retain the ASO insight about descriptions that summarize workflow causing agents to skip the skill body — this is a valuable discovery that complements the spec
- Reference the spec for all structural rules (S-1 through S-8) so future skills are authored in compliance

### 8. Rewrite "when not to use" without naming skills

The `reviewing-feature-branches` skill says "Not this skill: use requesting-code-review" for certain scenarios. Rewrite to describe the scenario without naming the alternative: "Not for reviewing code quality during iterative development or individual commits mid-implementation."

---

## Changes to CLAUDE.md

Remove the "Skills Usage" directive:

```
> The instructions in this section apply whenever using skills.

Use skills as process frameworks for complex tasks (debugging, TDD, verification), not as gatekeepers for every action. Don't let skills block direct tool use for straightforward tasks.
```

This directive was a patch for the coupling problem where brainstorming gated all creative work. The refactor fixes the root cause.

---

## What Does NOT Change

- Directory layout and naming conventions (`external/opencode/skills/<name>/SKILL.md`)
- Nix home-manager symlink strategy
- Client-specific config files (`work-opencode.json`, `tui.json`, Claude Code `settings.json`)
- Core skill content: methodologies, checklists, processes, supporting reference docs, scripts
- `AGENTS.md` (project instructions)
- Theme files

---

## Verification Plan

After refactoring, verify per the spec's verification rules:

- [ ] **V-1/V-2:** For each skill, test activation with 2-3 representative prompts (positive and negative)
- [ ] **V-3:** For each command, verify that dispatched agents have the tools and permissions their workflows require
- [ ] **V-4:** Load each agent with its full skill/instruction set and check for contradictions
- [ ] **V-5:** Run delegation round-trips: command → agent dispatch → result returned → usable by coordinator
- [ ] **V-7:** All components in version control
- [ ] **V-8:** Test compositions: build-feature end-to-end, execute-plan with both modes, debug → TDD integration
- [ ] **S-8 compliance:** grep all skills for component name references — must find zero
- [ ] **O-1 compliance:** only commands and agent configs reference components by name
- [ ] **Client agnosticism:** verify all agent definitions parse correctly in both OpenCode and Claude Code
