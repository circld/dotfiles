# Agentic Component Refactor Implementation Plan

**Goal:** Refactor all agentic AI components to adhere to the agentic component spec and be fully client/provider agnostic.

**Architecture:** Extract orchestration from skills into commands and agent definitions. Skills become pure knowledge units. All components use plain markdown, no client-specific markup.

**Design doc:** `docs/plans/2026-03-22-agentic-component-refactor-design.md`

**Spec:** `260320_agentic-component-spec.md`

---

## Task 1: Create spec-reviewer agent

**Files:**
- Create: `external/opencode/agents/spec-reviewer.md`

**Step 1: Write the agent definition**

Create `external/opencode/agents/spec-reviewer.md` with the following content. The reusable identity comes from `skills/subagent-driven-development/spec-reviewer-prompt.md`. The workflow-specific placeholders (`[FULL TEXT of task requirements]`, `[From implementer's report]`) and routing metadata (`Task tool (general-purpose)`) are removed — those are provided by commands at dispatch time.

```markdown
---
name: spec-reviewer
description: |
  Use this agent to verify that an implementation matches its specification.
  It returns pass/fail with specific deviations. Use for task-level or
  branch-level spec compliance checks.

  Example: A task from an implementation plan has been completed. Dispatch
  this agent with the task spec and changed files to verify compliance.
---

You are reviewing whether an implementation matches its specification.

## CRITICAL: Do Not Trust the Report

The implementer's report may be incomplete, inaccurate, or optimistic. You MUST verify everything independently.

**DO NOT:**
- Take their word for what they implemented
- Trust their claims about completeness
- Accept their interpretation of requirements

**DO:**
- Read the actual code they wrote
- Compare actual implementation to requirements line by line
- Check for missing pieces they claimed to implement
- Look for extra features they didn't mention

## Your Job

Read the implementation code and verify:

**Missing requirements:**
- Did they implement everything that was requested?
- Are there requirements they skipped or missed?
- Did they claim something works but didn't actually implement it?

**Extra/unneeded work:**
- Did they build things that weren't requested?
- Did they over-engineer or add unnecessary features?
- Did they add "nice to haves" that weren't in spec?

**Misunderstandings:**
- Did they interpret requirements differently than intended?
- Did they solve the wrong problem?
- Did they implement the right feature but wrong way?

**Verify by reading code, not by trusting report.**

## Output Format

Report:
- ✅ Spec compliant (if everything matches after code inspection)
- ❌ Issues found: [list specifically what's missing or extra, with file:line references]
```

**Step 2: Verify file created correctly**

Read the file back and confirm frontmatter parses (name, description fields present, no XML tags, no client-specific markup).

**Step 3: Commit**

```bash
git add external/opencode/agents/spec-reviewer.md
git commit -m "add spec-reviewer agent definition"
```

---

## Task 2: Create task-implementer agent

**Files:**
- Create: `external/opencode/agents/task-implementer.md`

**Step 1: Write the agent definition**

Create `external/opencode/agents/task-implementer.md`. The reusable identity comes from `skills/subagent-driven-development/implementer-prompt.md`. The workflow-specific placeholders and routing metadata are removed.

```markdown
---
name: task-implementer
description: |
  Use this agent to implement a single bounded task from a plan. It receives
  a task description, relevant context, and project standards, and produces
  a working implementation following TDD methodology.

  Example: An implementation plan has 8 tasks. Dispatch this agent for each
  task with the task description and dependencies from prior tasks.
---

You are implementing a single task from an implementation plan.

## Before You Begin

If you have questions about:
- The requirements or acceptance criteria
- The approach or implementation strategy
- Dependencies or assumptions
- Anything unclear in the task description

**Ask them now.** Raise any concerns before starting work.

## Your Job

Once you're clear on requirements:
1. Implement exactly what the task specifies
2. Follow TDD: write failing test first, then minimal implementation
3. Verify implementation works
4. Commit your work
5. Self-review (see below)
6. Report back

**While you work:** If you encounter something unexpected or unclear, **ask questions**. It's always OK to pause and clarify. Don't guess or make assumptions.

## Before Reporting Back: Self-Review

Review your work with fresh eyes. Ask yourself:

**Completeness:**
- Did I fully implement everything in the spec?
- Did I miss any requirements?
- Are there edge cases I didn't handle?

**Quality:**
- Is this my best work?
- Are names clear and accurate (match what things do, not how they work)?
- Is the code clean and maintainable?

**Discipline:**
- Did I avoid overbuilding (YAGNI)?
- Did I only build what was requested?
- Did I follow existing patterns in the codebase?

**Testing:**
- Do tests actually verify behavior (not just mock behavior)?
- Did I follow TDD (wrote test first, watched it fail)?
- Are tests comprehensive?

If you find issues during self-review, fix them now before reporting.

## Report Format

When done, report:
- What you implemented
- What you tested and test results
- Files changed
- Self-review findings (if any)
- Any issues or concerns
```

**Step 2: Verify file created correctly**

Read the file back and confirm frontmatter parses correctly.

**Step 3: Commit**

```bash
git add external/opencode/agents/task-implementer.md
git commit -m "add task-implementer agent definition"
```

---

## Task 3: Refactor code-reviewer agent

**Files:**
- Modify: `external/opencode/agents/code-reviewer.md`
- Read: `skills/requesting-code-review/code-reviewer.md` (absorb content)
- Read: `skills/reviewing-feature-branches/feature-branch-reviewer.md` (absorb evaluation criteria)

**Step 1: Rewrite the code-reviewer agent definition**

The current code-reviewer has `<example>/<commentary>` XML tags in its description. Replace with plain markdown. Merge in the review methodology from `requesting-code-review/code-reviewer.md` and the evaluation criteria from `reviewing-feature-branches/feature-branch-reviewer.md`. Remove workflow-specific placeholders — those come from commands.

Replace the entire file with:

```markdown
---
name: code-reviewer
description: |
  Use this agent to review code for quality, architecture, and adherence
  to project standards. It returns categorized issues (critical, important,
  suggestions) with actionable recommendations.

  Example: A feature implementation is complete and needs review before
  merging. Dispatch this agent with the changed files and project coding
  standards.

  Example: A batch of 3 tasks has been completed. Dispatch this agent with
  the changed files from the batch and the implementation plan as reference.
---

You are a Senior Code Reviewer with expertise in software architecture, design patterns, and best practices. Your role is to review code changes against a provided reference standard.

When reviewing, you will:

## 1. Reference Standard Alignment

- Compare the implementation against the provided reference (plan, spec, PR description, or standards)
- Identify any deviations from the expected approach, architecture, or requirements
- Assess whether deviations are justified improvements or problematic departures
- Verify that all expected functionality has been implemented

## 2. Code Quality Assessment

- Review code for adherence to established patterns and conventions
- Check for proper error handling, type safety, and defensive programming
- Evaluate code organization, naming conventions, and maintainability
- Look for potential security vulnerabilities or performance issues
- Check for DRY violations, dead code, and unclear abstractions

## 3. Architecture and Design Review

- Ensure the implementation follows SOLID principles and established architectural patterns
- Check for proper separation of concerns and loose coupling
- Verify that the code integrates well with existing systems
- Assess scalability and extensibility considerations

## 4. Test Quality

- Do tests verify behavior (not just exercise code)?
- Are edge cases covered?
- Integration tests where needed?
- All tests passing?

## 5. Security

- Hardcoded secrets, credentials, or tokens?
- User inputs validated and sanitized?
- New dependencies from trusted sources?
- Authorization/authentication gaps?
- Information leakage risks?
- Injection vectors (SQL, command, template, path traversal)?

## 6. Issue Categorization

Categorize all issues as:
- **Critical (Must Fix):** Bugs, security issues, data loss risks, broken functionality
- **Important (Should Fix):** Architecture problems, missing features, poor error handling, DRY violations, test gaps
- **Minor (Nice to Have):** Code style, naming, minor optimization

For each issue provide:
- File:line reference
- What's wrong
- Why it matters
- How to fix (if not obvious)

## Output Format

### Strengths
[What's well done — be specific with file:line references]

### Issues

#### Critical (Must Fix)
[List with file:line references]

#### Important (Should Fix)
[List with file:line references]

#### Minor (Nice to Have)
[List with file:line references]

### Recommendations
[Improvements for code quality, architecture, or process]

### Verdict

**Ready to merge?** [Yes / With fixes / No]

**Reasoning:** [2-3 sentences summarizing the overall assessment]

## Critical Rules

**DO:**
- Read the provided reference standard before reviewing any code
- Evaluate ALL changed files, not just source code — tests, config, docs all matter
- Categorize by actual severity (not everything is Critical)
- Be specific (file:line, not vague)
- Explain WHY issues matter
- Acknowledge strengths before highlighting issues
- Give clear verdict

**DON'T:**
- Say "looks good" without checking
- Mark nitpicks as Critical
- Give feedback on code you didn't review
- Be vague ("improve error handling")
- Avoid giving a clear verdict
- Assume the purpose is achieved just because code was written
- Ignore security issues because they seem unlikely to be exploited
```

**Step 2: Verify file has no XML tags or client-specific markup**

```bash
grep -E '<example>|<commentary>|TodoWrite|Task tool' external/opencode/agents/code-reviewer.md
```

Expected: no matches.

**Step 3: Commit**

```bash
git add external/opencode/agents/code-reviewer.md
git commit -m "refactor code-reviewer agent: plain markdown, absorb review templates"
```

---

## Task 4: Create all 9 command files

**Files:**
- Create: `external/opencode/commands/build-feature.md`
- Create: `external/opencode/commands/brainstorm.md`
- Create: `external/opencode/commands/write-plan.md`
- Create: `external/opencode/commands/execute-plan.md`
- Create: `external/opencode/commands/debug.md`
- Create: `external/opencode/commands/address-pr-reviews.md`
- Create: `external/opencode/commands/write-skill.md`
- Create: `external/opencode/commands/review-branch.md`
- Create: `external/opencode/commands/finish-branch.md`

**Step 1: Create each command file**

Copy the command definitions exactly as specified in the design doc (Section "Commands (9)"). Each file has YAML frontmatter (name, description, arguments) followed by the prompt template body.

The complete content for each command is in the design doc at:
- `build-feature`: design doc lines 113-188
- `brainstorm`: design doc lines 192-209
- `write-plan`: design doc lines 213-234
- `execute-plan`: design doc lines 238-312
- `debug`: design doc lines 316-333
- `address-pr-reviews`: design doc lines 337-360
- `write-skill`: design doc lines 364-386
- `review-branch`: design doc lines 390-426
- `finish-branch`: design doc lines 430-456

**Step 2: Verify all 9 files created**

```bash
ls external/opencode/commands/
```

Expected: 10 files (9 commands + .gitkeep).

**Step 3: Verify no client-specific markup in any command**

```bash
grep -rE '<example>|<commentary>|TodoWrite' external/opencode/commands/
```

Expected: no matches.

**Step 4: Commit**

```bash
git add external/opencode/commands/
git commit -m "add 9 command definitions for workflow orchestration"
```

---

## Task 5: Refactor brainstorming skill

**Files:**
- Modify: `external/opencode/skills/brainstorming/SKILL.md`

**Cross-references to strip:**
- `elements-of-style:writing-clearly-and-concisely skill if available` → "Write the design doc clearly and concisely"
- `superpowers:using-git-worktrees to create isolated workspace` → remove entirely (command handles)
- `superpowers:writing-plans to create detailed implementation plan` → remove entirely (command handles)

**Step 1: Rewrite frontmatter description**

Replace:
```yaml
description: "You MUST use this before any creative work - creating features, building components, adding functionality, or modifying behavior. Explores user intent, requirements and design before implementation."
```

With:
```yaml
description: "Use when the user requests new functionality, changes to existing behavior, or any task where the intent, scope, or approach is not fully obvious from the request. Err on the side of invoking — brief unnecessary clarification is cheaper than building the wrong thing. Not for purely mechanical tasks like renaming, reformatting, or running commands."
```

**Step 2: Rewrite "After the Design" section**

Replace:
```markdown
## After the Design

**Documentation:**
- Write the validated design to `docs/plans/YYYY-MM-DD-<topic>-design.md`
- Use elements-of-style:writing-clearly-and-concisely skill if available
- Commit the design document to git

**Implementation (if continuing):**
- Ask: "Ready to set up for implementation?"
- Use superpowers:using-git-worktrees to create isolated workspace
- Use superpowers:writing-plans to create detailed implementation plan
```

With:
```markdown
## After the Design

**Documentation:**
- Write the validated design to `docs/plans/YYYY-MM-DD-<topic>-design.md`
- Write the design doc clearly and concisely
- Commit the design document to git

**Next steps:**
- Ask: "Should I write this up as a design doc, or is the conversation sufficient?"
- If the user wants to continue to implementation, ask: "Ready to set up for implementation?"
```

**Step 3: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|elements-of-style:|TodoWrite|Task tool' external/opencode/skills/brainstorming/SKILL.md
```

Expected: no matches.

**Step 4: Commit**

```bash
git add external/opencode/skills/brainstorming/SKILL.md
git commit -m "refactor brainstorming skill: strip cross-refs, rewrite description"
```

---

## Task 6: Refactor writing-plans skill

**Files:**
- Modify: `external/opencode/skills/writing-plans/SKILL.md`

**Cross-references to strip:**
- `superpowers:executing-plans` in plan header and execution handoff
- `superpowers:subagent-driven-development` in execution handoff
- "Announce at start" pattern (client-specific behavior hint)
- "Context: This should be run in a dedicated worktree (created by brainstorming skill)" → remove (command handles)

**Step 1: Rewrite frontmatter description**

Replace:
```yaml
description: Use when you have a spec or requirements for a multi-step task, before touching code
```

With:
```yaml
description: "Use when you have a spec, design, or requirements for a multi-step task, before touching code. Not for single-step tasks or tasks with obvious implementation."
```

**Step 2: Remove the "Announce at start" and "Context" lines**

Remove:
```markdown
**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This should be run in a dedicated worktree (created by brainstorming skill).
```

**Step 3: Remove plan header skill directive**

In the plan header template, remove:
```markdown
> **For the agent:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
```

**Step 4: Rewrite execution handoff**

Replace the entire "Execution Handoff" section:
```markdown
## Execution Handoff

After saving the plan, offer execution choice:

**"Plan complete and saved to `docs/plans/<filename>.md`. Two execution options:**

**1. Subagent-Driven (this session)** - I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** - Open new session with executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:subagent-driven-development
- Stay in this session
- Fresh subagent per task + code review

**If Parallel Session chosen:**
- Guide them to open new session in worktree
- **REQUIRED SUB-SKILL:** New session uses superpowers:executing-plans
```

With:
```markdown
## Execution Handoff

After saving the plan, present execution choice:

**"Plan complete and saved to `docs/plans/<filename>.md`. Two execution options:**

**1. Subagent-Driven (this session)** — Fresh subagent per task, automated two-stage review (spec compliance then code quality), fast iteration.

**2. Batch Execution (this or separate session)** — Execute tasks in batches of 3, pause for human review between batches.

**Which approach?"**
```

**Step 5: Remove "Reference relevant skills with @ syntax" from Remember section**

Replace:
```markdown
- Reference relevant skills with @ syntax
```

With nothing (just remove the line).

**Step 6: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL|executing-plans|subagent-driven|brainstorming skill' external/opencode/skills/writing-plans/SKILL.md
```

Expected: no matches.

**Step 7: Commit**

```bash
git add external/opencode/skills/writing-plans/SKILL.md
git commit -m "refactor writing-plans skill: strip cross-refs, remove plan header directive"
```

---

## Task 7: Refactor executing-plans skill

**Files:**
- Modify: `external/opencode/skills/executing-plans/SKILL.md`

**Cross-references to strip:**
- `superpowers:finishing-a-development-branch` in Step 5
- `superpowers:using-git-worktrees` in Integration section
- `superpowers:writing-plans` in Integration section
- "Announce at start" pattern
- "Reference skills when plan says to" in Remember section
- Entire Integration section

**Step 1: Rewrite frontmatter description**

Replace:
```yaml
description: Use when you have a written implementation plan to execute in a separate session with review checkpoints
```

With:
```yaml
description: "Use when you have a written implementation plan to execute with batch-based human review checkpoints. Not for per-task subagent dispatch (use the subagent-driven approach instead)."
```

Wait — this description says "use the subagent-driven approach instead" which names another skill implicitly. Rewrite to:

```yaml
description: "Use when you have a written implementation plan to execute with batch-based human review checkpoints between groups of tasks. Not for automated per-task review workflows."
```

**Step 2: Remove "Announce at start" line**

Remove:
```markdown
**Announce at start:** "I'm using the executing-plans skill to implement this plan."
```

**Step 3: Rewrite Step 5**

Replace:
```markdown
### Step 5: Complete Development

After all tasks complete and verified:
- Announce: "I'm using the finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** Use superpowers:finishing-a-development-branch
- Follow that skill to verify tests, present options, execute choice
```

With:
```markdown
### Step 5: Complete Development

After all tasks complete and verified, proceed to integration:
- Verify all tests pass
- Present integration options to the user
```

**Step 4: Remove "Reference skills when plan says to" from Remember section**

Remove:
```markdown
- Reference skills when plan says to
```

**Step 5: Remove entire Integration section**

Remove:
```markdown
## Integration

**Required workflow skills:**
- **superpowers:using-git-worktrees** - REQUIRED: Set up isolated workspace before starting
- **superpowers:writing-plans** - Creates the plan this skill executes
- **superpowers:finishing-a-development-branch** - Complete development after all tasks
```

**Step 6: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL|finishing-a-development|using-git-worktrees|writing-plans' external/opencode/skills/executing-plans/SKILL.md
```

Expected: no matches.

**Step 7: Commit**

```bash
git add external/opencode/skills/executing-plans/SKILL.md
git commit -m "refactor executing-plans skill: strip cross-refs, remove Integration section"
```

---

## Task 8: Refactor subagent-driven-development skill

**Files:**
- Modify: `external/opencode/skills/subagent-driven-development/SKILL.md`
- Delete: `external/opencode/skills/subagent-driven-development/implementer-prompt.md` (dissolved into task-implementer agent)
- Delete: `external/opencode/skills/subagent-driven-development/spec-reviewer-prompt.md` (dissolved into spec-reviewer agent)
- Delete: `external/opencode/skills/subagent-driven-development/code-quality-reviewer-prompt.md` (dissolved into code-reviewer agent)

**Cross-references to strip:**
- `./implementer-prompt.md`, `./spec-reviewer-prompt.md`, `./code-quality-reviewer-prompt.md` references
- `superpowers:using-git-worktrees` in Integration
- `superpowers:writing-plans` in Integration
- `superpowers:requesting-code-review` in Integration
- `superpowers:finishing-a-development-branch` in Integration
- `superpowers:test-driven-development` in Integration
- `superpowers:executing-plans` in Alternative workflow
- `executing-plans` in When to Use flowchart and comparison
- `TodoWrite` references
- `Task tool` references in Prompt Templates section

**Step 1: Rewrite frontmatter description**

Keep current (already spec-compliant):
```yaml
description: Use when executing implementation plans with independent tasks in the current session
```

Add "when not to use":
```yaml
description: "Use when executing implementation plans with independent tasks using per-task subagent dispatch in the current session. Not for tightly coupled tasks that must share context, or batch execution with human review between groups."
```

**Step 2: Rewrite the process flowchart**

The current flowchart references prompt template files. Replace file references with domain-level actions:
- `"Dispatch implementer subagent (./implementer-prompt.md)"` → `"Dispatch implementer subagent"`
- `"Dispatch spec reviewer subagent (./spec-reviewer-prompt.md)"` → `"Dispatch spec reviewer subagent"`
- `"Dispatch code quality reviewer subagent (./code-quality-reviewer-prompt.md)"` → `"Dispatch code quality reviewer subagent"`
- `"Mark task complete in TodoWrite"` → `"Mark task complete"`
- `"Use finishing-a-development-branch workflow"` → `"Proceed to integration"`

**Step 3: Remove Prompt Templates section**

Remove:
```markdown
## Prompt Templates

- `./implementer-prompt.md` - Dispatch implementer subagent
- `./spec-reviewer-prompt.md` - Dispatch spec compliance reviewer subagent
- `./code-quality-reviewer-prompt.md` - Dispatch code quality reviewer subagent
```

**Step 4: Rewrite "When to Use" flowchart**

Remove references to `executing-plans` by name. Replace with descriptions:
- `"executing-plans"` node → `"Batch execution with human review"`
- `"subagent-driven-development"` node → `"Per-task subagent dispatch"`

**Step 5: Rewrite "vs. Executing Plans" comparison**

Replace `"vs. Executing Plans (parallel session):"` with `"vs. batch execution:"`. Remove the skill name reference.

**Step 6: Remove entire Integration section**

Remove:
```markdown
## Integration

**Required workflow skills:**
- **using-git-worktrees** - REQUIRED: Set up isolated workspace before starting
- **writing-plans** - Creates the plan this skill executes
- **requesting-code-review** - Code review template for reviewer subagents
- **finishing-a-development-branch** - Complete development after all tasks

**Subagents should use:**
- **test-driven-development** - Subagents follow TDD for each task

**Alternative workflow:**
- **executing-plans** - Use for parallel session instead of same-session execution
```

**Step 7: Rewrite Red Flags to remove tool references**

Replace `"Mark task complete in TodoWrite"` references with `"Mark task complete"`.

**Step 8: Delete dissolved prompt templates**

```bash
rm external/opencode/skills/subagent-driven-development/implementer-prompt.md
rm external/opencode/skills/subagent-driven-development/spec-reviewer-prompt.md
rm external/opencode/skills/subagent-driven-development/code-quality-reviewer-prompt.md
```

**Step 9: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL|TodoWrite|Task tool|executing-plans|writing-plans|requesting-code-review|finishing-a-development|test-driven-development|using-git-worktrees|\./implementer|\./spec-reviewer|\./code-quality' external/opencode/skills/subagent-driven-development/SKILL.md
```

Expected: no matches.

**Step 10: Commit**

```bash
git add external/opencode/skills/subagent-driven-development/
git commit -m "refactor subagent-driven-development: strip cross-refs, dissolve prompt templates"
```

---

## Task 9: Refactor using-git-worktrees skill

**Files:**
- Modify: `external/opencode/skills/using-git-worktrees/SKILL.md`

**Cross-references to strip:**
- "Announce at start" pattern
- `CLAUDE.md` reference in directory selection (this is acceptable — CLAUDE.md is a project file, not a component)
- Entire Integration section (Called by / Pairs with)

**Step 1: Remove "Announce at start" line**

Remove:
```markdown
**Announce at start:** "I'm using the using-git-worktrees skill to set up an isolated workspace."
```

**Step 2: Remove entire Integration section**

Remove:
```markdown
## Integration

**Called by:**
- **brainstorming** (Phase 4) - REQUIRED when design is approved and implementation follows
- **subagent-driven-development** - REQUIRED before executing any tasks
- **executing-plans** - REQUIRED before executing any tasks
- Any skill needing isolated workspace

**Pairs with:**
- **finishing-a-development-branch** - REQUIRED for cleanup after work complete
```

**Step 3: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|brainstorming|subagent-driven|executing-plans|finishing-a-development' external/opencode/skills/using-git-worktrees/SKILL.md
```

Expected: no matches.

**Step 4: Commit**

```bash
git add external/opencode/skills/using-git-worktrees/SKILL.md
git commit -m "refactor using-git-worktrees skill: remove Integration section"
```

---

## Task 10: Refactor finishing-a-development-branch skill

**Files:**
- Modify: `external/opencode/skills/finishing-a-development-branch/SKILL.md`

**Cross-references to strip:**
- "Announce at start" pattern
- Entire Integration section (Called by / Pairs with)

**Step 1: Remove "Announce at start" line**

Remove:
```markdown
**Announce at start:** "I'm using the finishing-a-development-branch skill to complete this work."
```

**Step 2: Fix Option 2 worktree contradiction**

The skill body says "Then: Cleanup worktree (Step 5)" for Option 2, but the Quick Reference table and Common Mistakes section say to keep the worktree for Option 2. Fix by removing the worktree cleanup reference from Option 2:

In Option 2 section, remove:
```markdown
Then: Cleanup worktree (Step 5)
```

Replace with:
```markdown
Keep worktree (may need for review feedback).
```

**Step 3: Remove entire Integration section**

Remove:
```markdown
## Integration

**Called by:**
- **subagent-driven-development** (Step 7) - After all tasks complete
- **executing-plans** (Step 5) - After all batches complete

**Pairs with:**
- **using-git-worktrees** - Cleans up worktree created by that skill
```

**Step 4: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|subagent-driven|executing-plans|using-git-worktrees' external/opencode/skills/finishing-a-development-branch/SKILL.md
```

Expected: no matches.

**Step 5: Commit**

```bash
git add external/opencode/skills/finishing-a-development-branch/SKILL.md
git commit -m "refactor finishing-a-development-branch: fix worktree bug, remove Integration"
```

---

## Task 11: Refactor systematic-debugging skill

**Files:**
- Modify: `external/opencode/skills/systematic-debugging/SKILL.md`

**Cross-references to strip:**
- `superpowers:test-driven-development` in Phase 4 Step 1
- `superpowers:verification-before-completion` in Related skills
- Entire "Related skills" subsection within Supporting Techniques

**Step 1: Replace TDD skill reference in Phase 4**

Replace:
```markdown
   - Use the `superpowers:test-driven-development` skill for writing proper failing tests
```

With:
```markdown
   - Follow TDD methodology for writing proper failing tests
```

**Step 2: Remove Related skills from Supporting Techniques**

Remove:
```markdown
**Related skills:**
- **superpowers:test-driven-development** - For creating failing test case (Phase 4, Step 1)
- **superpowers:verification-before-completion** - Verify fix worked before claiming success
```

**Step 3: Verify no cross-references remain**

```bash
grep -iE 'superpowers:' external/opencode/skills/systematic-debugging/SKILL.md
```

Expected: no matches.

**Step 4: Commit**

```bash
git add external/opencode/skills/systematic-debugging/SKILL.md
git commit -m "refactor systematic-debugging skill: strip skill cross-refs"
```

---

## Task 12: Refactor test-driven-development skill

**Files:**
- Modify: `external/opencode/skills/test-driven-development/SKILL.md`

**Cross-references to check:**
- `@testing-anti-patterns.md` — this is a local supporting file reference, NOT a skill reference. Keep as-is.

**Step 1: Verify no skill cross-references exist**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL' external/opencode/skills/test-driven-development/SKILL.md
```

Expected: no matches. This skill is already nearly compliant — no outward orchestration references.

**Step 2: No changes needed**

This skill is already a pure knowledge unit. The `@testing-anti-patterns.md` reference is a local file within the same skill directory (category A — supporting reference doc).

**Step 3: Commit (skip if no changes)**

No commit needed.

---

## Task 13: Refactor reviewing-feature-branches skill

**Files:**
- Modify: `external/opencode/skills/reviewing-feature-branches/SKILL.md`
- Modify: `external/opencode/skills/reviewing-feature-branches/pr-comment-template.md`
- Delete: `external/opencode/skills/reviewing-feature-branches/feature-branch-reviewer.md` (dissolved into code-reviewer agent)

**Cross-references to strip:**
- `requesting-code-review` in "Not this skill" section
- `code-reviewer` subagent dispatch instructions
- `Task tool with code-reviewer type` reference
- `feature-branch-reviewer.md` template reference
- `finishing-a-development-branch` in Integration section
- Entire Integration section

**Step 1: Rewrite "Not this skill" without naming skills**

Replace:
```markdown
**Not this skill:**
- Reviewing code quality during iterative development (use requesting-code-review)
- Reviewing individual commits mid-implementation (use requesting-code-review)
```

With:
```markdown
**Not for:**
- Reviewing code quality during iterative development or individual commits mid-implementation
- Per-task code review during plan execution
```

**Step 2: Rewrite "How to Review" to remove dispatch instructions**

The current skill has detailed dispatch instructions (Task tool, template placeholders, subagent type). These are orchestration concerns that now live in the `review-branch` command. Replace with domain-level actions:

Replace section "3. Dispatch feature-branch-reviewer subagent:" and its placeholder instructions with:
```markdown
**3. Review the branch:**

Evaluate all changes against the stated purpose. Check:
- Objective achievement: map each goal to concrete changes
- Engineering best practice: DRY, naming, dead code, error handling, test quality
- Security: secrets, input validation, dependencies, auth gaps, injection vectors
- Scope: creep (work serving no stated objective) and gaps (objectives with no implementation)
```

**Step 3: Remove template file reference**

Remove:
```markdown
**Subagent template:** See `feature-branch-reviewer.md`
```

**Step 4: Remove Integration section**

Remove:
```markdown
## Integration

**Complements:**
- **requesting-code-review** - General code quality during development
- **finishing-a-development-branch** - Use this skill as part of the finishing workflow

**Subagent template:** See `feature-branch-reviewer.md`
```

**Step 5: Make pr-comment-template.md client-agnostic**

In `pr-comment-template.md`, replace:
```markdown
> Automated review by OpenCode against PR description.
```

With:
```markdown
> Automated review against PR description.
```

**Step 6: Delete dissolved template**

```bash
rm external/opencode/skills/reviewing-feature-branches/feature-branch-reviewer.md
```

**Step 7: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|requesting-code-review|finishing-a-development|code-reviewer|feature-branch-reviewer|Task tool|OpenCode' external/opencode/skills/reviewing-feature-branches/SKILL.md external/opencode/skills/reviewing-feature-branches/pr-comment-template.md
```

Expected: no matches.

**Step 8: Commit**

```bash
git add external/opencode/skills/reviewing-feature-branches/
git commit -m "refactor reviewing-feature-branches: strip cross-refs, dissolve template, client-agnostic"
```

---

## Task 14: Refactor address-pr-reviews skill

**Files:**
- Modify: `external/opencode/skills/address-pr-reviews/SKILL.md`

**Cross-references to check:**
- `triggers` field in frontmatter — this is an OpenCode-specific feature. Remove for client agnosticism.
- `version` field — non-standard, remove.

**Step 1: Rewrite frontmatter**

Replace:
```yaml
---
name: address-pr-reviews
description: |
  Address PR review comments - fix issues, reply to threads, mark resolved
version: 3.0.0
triggers:
  # Direct invocations
  - address pr reviews
  ...
---
```

With:
```yaml
---
name: address-pr-reviews
description: "Use when addressing PR review comments — fixing issues, replying to threads, marking resolved. Not for creating reviews of code or branches."
---
```

**Step 2: Verify no skill cross-references exist**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL' external/opencode/skills/address-pr-reviews/SKILL.md
```

Expected: no matches. This skill has no outward skill references.

**Step 3: Commit**

```bash
git add external/opencode/skills/address-pr-reviews/SKILL.md
git commit -m "refactor address-pr-reviews skill: client-agnostic frontmatter"
```

---

## Task 15: Refactor writing-skills skill

**Files:**
- Modify: `external/opencode/skills/writing-skills/SKILL.md`

This is the largest skill refactor. The writing-skills skill contains ad-hoc guidance that overlaps with and should now reference the agentic component spec.

**Cross-references to strip:**
- `superpowers:test-driven-development` in multiple places (REQUIRED BACKGROUND, Iron Law section, TDD Mapping)
- `superpowers:systematic-debugging` if present
- `@testing-skills-with-subagents.md` — local file reference, keep
- `@graphviz-conventions.dot` — local file reference, keep
- Cross-referencing section using `superpowers:` prefix convention

**Step 1: Replace REQUIRED BACKGROUND reference**

Replace:
```markdown
**REQUIRED BACKGROUND:** You MUST understand superpowers:test-driven-development before using this skill. That skill defines the fundamental RED-GREEN-REFACTOR cycle. This skill adapts TDD to documentation.
```

With:
```markdown
**REQUIRED BACKGROUND:** You must understand TDD methodology (RED-GREEN-REFACTOR cycle) before using this skill. This skill adapts TDD to documentation.
```

**Step 2: Replace TDD reference in Iron Law section**

Replace:
```markdown
**REQUIRED BACKGROUND:** The superpowers:test-driven-development skill explains why this matters. Same principles apply to documentation.
```

With:
```markdown
The TDD methodology explains why this matters. Same principles apply to documentation.
```

**Step 3: Rewrite Cross-Referencing section to reference the spec**

Replace the entire "### 4. Cross-Referencing Other Skills" section:

```markdown
**When writing documentation that references other skills:**

Use skill name only, with explicit requirement markers:
- ✅ Good: `**REQUIRED SUB-SKILL:** Use superpowers:test-driven-development`
- ✅ Good: `**REQUIRED BACKGROUND:** You MUST understand superpowers:systematic-debugging`
- ❌ Bad: `See skills/testing/test-driven-development` (unclear if required)
- ❌ Bad: `@skills/testing/test-driven-development/SKILL.md` (force-loads, burns context)

**Why no @ links:** `@` syntax force-loads files immediately, consuming 200k+ context before you need them.
```

With:

```markdown
### 4. No Cross-References to Other Components

Per the agentic component spec (S-8): **Skills must not depend on specific platform components.** A skill does not name specific tools, agents, other skills, or commands. It describes domain-level actions that any suitably-equipped agent can map to its own tool set.

- ❌ Bad: `**REQUIRED SUB-SKILL:** Use superpowers:test-driven-development`
- ❌ Bad: `Use TodoWrite to track progress`
- ❌ Bad: `Dispatch code-reviewer subagent`
- ✅ Good: `Follow TDD methodology`
- ✅ Good: `Track task progress`
- ✅ Good: `Request a code review of the changes`

**Why:** Skills are pure, composable knowledge units (O-3). Only agents and commands reference other components by name (O-1). Orchestration sequences belong in commands, not skills.

References to local supporting files within the same skill directory (e.g., `@supporting-doc.md`) are acceptable — these are part of the skill, not external dependencies.
```

**Step 4: Add spec reference to SKILL.md Structure section**

After the existing structure guidance, add:

```markdown
**Spec compliance:** All skills must comply with the agentic component spec rules S-1 through S-8. Key rules:
- **S-1:** Single responsibility — one workflow, one domain, one procedure
- **S-2:** Write the description for the router — trigger conditions, not summaries
- **S-4:** Domain-level actions, not tool-level actions
- **S-6:** Include "when to use" and "when not to use"
- **S-8:** No references to specific platform components

See `260320_agentic-component-spec.md` for the complete specification.
```

**Step 5: Retain the ASO insight**

Keep the "CRITICAL: Description = When to Use, NOT What the Skill Does" section in Agent Search Optimization — this is a valuable discovery that complements S-2. No changes needed here.

**Step 6: Update cross-reference examples in Token Efficiency section**

Replace:
```markdown
**Use cross-references:**
```markdown
# ❌ BAD: Repeat workflow details
When searching, dispatch subagent with template...
[20 lines of repeated instructions]

# ✅ GOOD: Reference other skill
Always use subagents (50-100x context savings). REQUIRED: Use [other-skill-name] for workflow.
```

With:
```markdown
**Minimize repetition:**
```markdown
# ❌ BAD: Repeat detailed instructions inline
When searching, dispatch subagent with template...
[20 lines of repeated instructions]

# ✅ GOOD: Describe the action at domain level
Always use subagents for search (50-100x context savings).
```

**Step 7: Verify no cross-references remain**

```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL|REQUIRED BACKGROUND.*superpowers' external/opencode/skills/writing-skills/SKILL.md
```

Expected: no matches (except in the "❌ Bad" examples which are illustrative).

**Step 8: Commit**

```bash
git add external/opencode/skills/writing-skills/SKILL.md
git commit -m "refactor writing-skills: reference agentic component spec, strip cross-refs"
```

---

## Task 16: Add verification-before-completion skill

**Files:**
- Create: `external/opencode/skills/verification-before-completion/SKILL.md`

**Step 1: Create the skill**

Fetch the skill from the upstream repo and save it:

```bash
curl -s https://raw.githubusercontent.com/obra/superpowers/main/skills/verification-before-completion/SKILL.md > external/opencode/skills/verification-before-completion/SKILL.md
```

**Step 2: Verify the skill is spec-compliant**

Check for cross-references:
```bash
grep -iE 'superpowers:|REQUIRED SUB-SKILL' external/opencode/skills/verification-before-completion/SKILL.md
```

If any found, strip them following the same pattern as other skills.

**Step 3: Commit**

```bash
git add external/opencode/skills/verification-before-completion/
git commit -m "add verification-before-completion skill"
```

---

## Task 17: Remove requesting-code-review skill

**Files:**
- Delete: `external/opencode/skills/requesting-code-review/` (entire directory)

The content has been absorbed into:
- `code-reviewer` agent definition (review methodology, output format, checklist)
- Command templates (when to dispatch, what context to provide)

**Step 1: Delete the directory**

```bash
rm -rf external/opencode/skills/requesting-code-review/
```

**Step 2: Verify deletion**

```bash
ls external/opencode/skills/requesting-code-review/ 2>&1
```

Expected: "No such file or directory"

**Step 3: Verify no remaining references to requesting-code-review**

```bash
grep -r 'requesting-code-review' external/opencode/
```

Expected: no matches.

**Step 4: Commit**

```bash
git add -A external/opencode/skills/requesting-code-review/
git commit -m "remove requesting-code-review skill (absorbed into code-reviewer agent)"
```

---

## Task 18: Update CLAUDE.md

**Files:**
- Modify: `AGENTS.md` (the file that gets symlinked to `~/.claude/CLAUDE.md`)

Note: The actual CLAUDE.md is at `/Users/paul.grow/.claude/CLAUDE.md` which is a symlink managed by Nix. The source file is `external/opencode/AGENTS.md`.

**Step 1: Remove the Skills Usage directive**

Remove:
```markdown
# Skills Usage

> The instructions in this section apply whenever using skills.

Use skills as process frameworks for complex tasks (debugging, TDD, verification), not as gatekeepers for every action. Don't let skills block direct tool use for straightforward tasks.
```

**Step 2: Verify the directive is gone**

```bash
grep -i 'skills usage\|gatekeepers' external/opencode/AGENTS.md
```

Expected: no matches.

**Step 3: Commit**

```bash
git add external/opencode/AGENTS.md
git commit -m "remove Skills Usage directive from AGENTS.md (root cause fixed by refactor)"
```

---

## Task 19: Front-load decision-relevant content (S-3)

Per design doc refactoring rule #3: "Critical workflow steps and decision criteria at the top. Supplementary context and edge cases at the bottom."

**Files:**
- Review and reorder: all 12 skill SKILL.md files

**Step 1: Audit each skill for content ordering**

For each skill, verify that:
- The most important workflow steps appear in the first section after the overview
- Decision criteria and "when to use / when not to use" are near the top
- Edge cases, common mistakes, rationalizations, and reference material are near the bottom
- Quick reference tables are positioned for easy scanning

Skills most likely to need reordering:
- `systematic-debugging`: Phase 1 (root cause investigation) is correctly first — verify remaining phases are in priority order
- `writing-skills`: The TDD mapping, skill types, and structure sections should come before the ASO optimization and anti-patterns sections
- `subagent-driven-development`: The process flowchart should come before the example workflow and advantages comparison

**Step 2: Reorder where needed**

For each skill that needs reordering, move sections without changing their content. Do not rewrite — only reorder.

**Step 3: Commit**

```bash
git add external/opencode/skills/
git commit -m "reorder skill content: front-load decision-relevant information (S-3)"
```

---

## Task 20: Static compliance verification

**Step 1: S-8 compliance — no skill-to-skill cross-references**

```bash
grep -rE 'superpowers:|REQUIRED SUB-SKILL|REQUIRED BACKGROUND.*superpowers' external/opencode/skills/ --include='*.md'
```

Expected: no matches (except illustrative "❌ Bad" examples in writing-skills).

**Step 2: O-1 compliance — only commands and agents reference components by name**

```bash
grep -rE 'brainstorming skill|writing-plans skill|executing-plans skill|code-reviewer|spec-reviewer|task-implementer' external/opencode/skills/ --include='SKILL.md'
```

Expected: no matches.

**Step 3: Client agnosticism — no client-specific markup**

```bash
grep -rE '<example>|<commentary>|TodoWrite|Task tool|OpenCode' external/opencode/ --include='*.md'
```

Expected: no matches (except possibly in AGENTS.md if it has unrelated content).

**Step 4: No dangling references to deleted files**

```bash
grep -rE 'implementer-prompt|spec-reviewer-prompt|code-quality-reviewer-prompt|feature-branch-reviewer|requesting-code-review' external/opencode/ --include='*.md'
```

Expected: no matches.

**Step 5: All prompt templates dissolved**

```bash
ls external/opencode/skills/subagent-driven-development/implementer-prompt.md 2>&1
ls external/opencode/skills/subagent-driven-development/spec-reviewer-prompt.md 2>&1
ls external/opencode/skills/subagent-driven-development/code-quality-reviewer-prompt.md 2>&1
ls external/opencode/skills/reviewing-feature-branches/feature-branch-reviewer.md 2>&1
ls external/opencode/skills/requesting-code-review/ 2>&1
```

Expected: all "No such file or directory."

**Step 6: V-7 — all components in version control**

```bash
git status
```

Expected: no untracked component files. All agents, commands, and skills committed.

**Step 7: Report results**

Present pass/fail for each check. If any fail, identify the specific file and line.

---

## Task 21: Dynamic verification — activation testing (V-1, V-2)

For each skill, test with 2-3 representative prompts to verify the agent loads the correct skill.

**Step 1: Positive activation tests**

For each skill, send a prompt that should trigger it and verify the skill is loaded:

| Skill | Test prompt |
|---|---|
| `brainstorming` | "I want to add a caching layer to the API" |
| `brainstorming` | "Let's rethink how we handle errors" |
| `writing-plans` | "Here's the design doc, write an implementation plan" |
| `executing-plans` | "Execute this plan in batches with review checkpoints" |
| `using-git-worktrees` | "Set up an isolated workspace for this feature" |
| `finishing-a-development-branch` | "I'm done implementing, what are my options?" |
| `test-driven-development` | "Implement a retry function for failed API calls" |
| `systematic-debugging` | "Tests are failing with a timeout error" |
| `subagent-driven-development` | "Execute this plan with fresh subagents per task" |
| `reviewing-feature-branches` | "Review this branch against the PR description" |
| `address-pr-reviews` | "Address the review comments on PR #42" |
| `writing-skills` | "Create a new skill for database migration patterns" |
| `verification-before-completion` | (should auto-activate when agent claims work is done) |

**Step 2: Negative activation tests**

Verify skills do NOT activate for these prompts:

| Skill | Should NOT trigger for |
|---|---|
| `brainstorming` | "Rename this function to snake_case" |
| `brainstorming` | "Run the test suite" |
| `systematic-debugging` | "Add a new endpoint for user profiles" |
| `writing-plans` | "Fix this typo in the README" |

**Step 3: Report activation results**

For each test, record: prompt → skill loaded (or not) → pass/fail.

---

## Task 22: Dynamic verification — capability alignment (V-3)

**Step 1: Verify agent tool access**

For each command that dispatches agents, verify the agent has the tools its workflow requires:

| Command | Agent dispatched | Required capabilities |
|---|---|---|
| `execute-plan` | `task-implementer` | File read, file write, bash (tests), git |
| `execute-plan` | `spec-reviewer` | File read (must read implementation code) |
| `execute-plan` | `code-reviewer` | File read, git diff |
| `review-branch` | `code-reviewer` | File read, git diff, gh CLI |
| `build-feature` | All three agents | Same as execute-plan |

**Step 2: Test each agent has required access**

Dispatch each agent with a minimal test task and verify it can perform its required operations without permission errors.

**Step 3: Report capability alignment**

For each agent: capabilities required → capabilities available → pass/fail.

---

## Task 23: Dynamic verification — context conflicts (V-4)

**Step 1: Check for contradictions in combined contexts**

For each command, identify the full set of skills and instructions that will be active simultaneously and check for contradictions:

| Command | Active skills | Check for |
|---|---|---|
| `build-feature` | brainstorming + writing-plans + executing-plans + TDD + finishing | Conflicting process steps, contradictory advice |
| `execute-plan` (subagent) | subagent-driven-dev + TDD + verification-before-completion | Conflicting review requirements |
| `debug` | systematic-debugging + TDD + verification-before-completion | Conflicting "when to fix" guidance |

**Step 2: Read each combination and identify conflicts**

For each combination, read all active skills and the AGENTS.md instructions. Look for:
- Contradictory sequencing (one skill says "do X before Y", another says "do Y before X")
- Conflicting constraints (one skill says "never do X", another says "always do X")
- Ambiguous authority (two skills give different advice for the same situation)

**Step 3: Report conflicts**

List any conflicts found with specific file:line references. If conflicts exist, resolve them before considering verification complete.

---

## Task 24: Dynamic verification — delegation round-trips (V-5)

**Step 1: Test execute-plan delegation chain**

Run a minimal execute-plan scenario (1 task):
1. Dispatch task-implementer with a trivial task description
2. Verify implementer returns a usable report (what was implemented, files changed, test results)
3. Dispatch spec-reviewer with the task spec and implementer's report
4. Verify spec-reviewer returns pass/fail with specific findings
5. Dispatch code-reviewer with the changed files
6. Verify code-reviewer returns categorized issues and verdict

**Step 2: Test review-branch delegation**

1. On a branch with changes, invoke the review-branch command
2. Verify code-reviewer receives the stated purpose and diff
3. Verify the review is returned in the expected format (strengths, issues, verdict)
4. Verify the PR comment posting flow works (POST/EDIT/DO NOTHING)

**Step 3: Report round-trip results**

For each delegation: input provided → output received → output usable by coordinator → pass/fail.

---

## Task 25: Dynamic verification — composition testing (V-8)

**Step 1: End-to-end build-feature test**

Run `/build-feature "add a hello world endpoint"` through:
- Phase 1 (brainstorming activates, explores the idea)
- Phase 2 (complexity assessment, user decides)
- Phase 3 (plan written if requested)
- Phase 4 (implementation with review cycles)
- Phase 5 (finish-branch options presented)

Verify the user experiences the same sequence of events as the pre-refactor workflow.

**Step 2: Execute-plan with both modes**

Test both execution modes with a 2-task plan:
- Subagent-driven: verify per-task dispatch, two-stage review (spec then code), review loops
- Batch: verify batch-of-3 grouping, human checkpoint between batches

**Step 3: Debug → TDD integration**

Invoke `/debug "test X is failing"` and verify:
- Systematic debugging skill loads and guides root cause investigation
- When Phase 4 creates a failing test, TDD methodology is followed
- verification-before-completion activates when claiming the fix is complete

**Step 4: Report composition results**

For each end-to-end test: expected sequence → actual sequence → deviations → pass/fail.
