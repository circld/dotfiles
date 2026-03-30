---
name: subagent-driven-development
description: "Use when executing implementation plans with independent tasks using per-task subagent dispatch in the current session. Not for tightly coupled tasks that must share context, or batch execution with human review between groups."
---

# Subagent-Driven Development

Execute plan by dispatching fresh subagent per task, with two-stage review after each: spec compliance review first, then code quality review.

**Core principle:** Fresh subagent per task + two-stage review (spec then quality) = high quality, fast iteration

## When to Use

```dot
digraph when_to_use {
    "Have implementation plan?" [shape=diamond];
    "Tasks mostly independent?" [shape=diamond];
    "Stay in this session?" [shape=diamond];
    "per-task subagent dispatch" [shape=box];
    "batch execution with human review" [shape=box];
    "Manual execution or brainstorm first" [shape=box];

    "Have implementation plan?" -> "Tasks mostly independent?" [label="yes"];
    "Have implementation plan?" -> "Manual execution or brainstorm first" [label="no"];
    "Tasks mostly independent?" -> "Stay in this session?" [label="yes"];
    "Tasks mostly independent?" -> "Manual execution or brainstorm first" [label="no - tightly coupled"];
    "Stay in this session?" -> "per-task subagent dispatch" [label="yes"];
    "Stay in this session?" -> "batch execution with human review" [label="no - parallel session"];
}
```

**vs. batch execution:**
- Same session (no context switch)
- Fresh subagent per task (no context pollution)
- Two-stage review after each task: spec compliance first, then code quality
- Faster iteration (no human-in-loop between tasks)

## The Process

```dot
digraph process {
    rankdir=TB;

    subgraph cluster_per_task {
        label="Per Task";
        "Implement task" [shape=box];
        "Questions before starting?" [shape=diamond];
        "Answer questions, provide context" [shape=box];
        "Implement, test, commit, self-review" [shape=box];
        "Verify spec compliance" [shape=box];
        "Code matches spec?" [shape=diamond];
        "Fix spec gaps" [shape=box];
        "Review code quality" [shape=box];
        "Code quality approved?" [shape=diamond];
        "Fix quality issues" [shape=box];
        "Mark task complete" [shape=box];
    }

    "Read plan, extract all tasks with full text, note context, track task progress" [shape=box];
    "More tasks remain?" [shape=diamond];
    "Final code quality review of entire implementation" [shape=box];
    "Proceed to integration" [shape=box style=filled fillcolor=lightgreen];

    "Read plan, extract all tasks with full text, note context, track task progress" -> "Implement task";
    "Implement task" -> "Questions before starting?";
    "Questions before starting?" -> "Answer questions, provide context" [label="yes"];
    "Answer questions, provide context" -> "Implement task";
    "Questions before starting?" -> "Implement, test, commit, self-review" [label="no"];
    "Implement, test, commit, self-review" -> "Verify spec compliance";
    "Verify spec compliance" -> "Code matches spec?";
    "Code matches spec?" -> "Fix spec gaps" [label="no"];
    "Fix spec gaps" -> "Verify spec compliance" [label="re-review"];
    "Code matches spec?" -> "Review code quality" [label="yes"];
    "Review code quality" -> "Code quality approved?";
    "Code quality approved?" -> "Fix quality issues" [label="no"];
    "Fix quality issues" -> "Review code quality" [label="re-review"];
    "Code quality approved?" -> "Verify independently (run tests, check VCS diff)" [label="yes"];
    "Verify independently (run tests, check VCS diff)" -> "Mark task complete";
    "Mark task complete" -> "More tasks remain?";
    "More tasks remain?" -> "Implement task" [label="yes"];
    "More tasks remain?" -> "Final code quality review of entire implementation" [label="no"];
    "Final code quality review of entire implementation" -> "Proceed to integration";
}
```

## Example Workflow

```
You: I'm using Subagent-Driven Development to execute this plan.

[Read plan file once: docs/plans/feature-plan.md]
[Extract all 5 tasks with full text and context]
[Track task progress for all tasks]

Task 1: Hook installation script

[Get Task 1 text and context (already extracted)]
[Dispatch subagent with full task text + context]

Implementer: "Before I begin - should the hook be installed at user or system level?"

You: "User level (~/.config/superpowers/hooks/)"

Implementer: "Got it. Implementing now..."
[Later] Implementer:
  - Implemented install-hook command
  - Added tests, 5/5 passing
  - Self-review: Found I missed --force flag, added it
  - Committed

[Dispatch spec compliance reviewer]
Spec reviewer: ✅ Spec compliant - all requirements met, nothing extra

[Get git SHAs, dispatch code quality reviewer]
Code reviewer: Strengths: Good test coverage, clean. Issues: None. Approved.

[Mark Task 1 complete]

Task 2: Recovery modes

[Get Task 2 text and context (already extracted)]
[Dispatch subagent with full task text + context]

Implementer: [No questions, proceeds]
Implementer:
  - Added verify/repair modes
  - 8/8 tests passing
  - Self-review: All good
  - Committed

[Dispatch spec compliance reviewer]
Spec reviewer: ❌ Issues:
  - Missing: Progress reporting (spec says "report every 100 items")
  - Extra: Added --json flag (not requested)

[Implementer fixes issues]
Implementer: Removed --json flag, added progress reporting

[Spec reviewer reviews again]
Spec reviewer: ✅ Spec compliant now

[Dispatch code quality reviewer]
Code reviewer: Strengths: Solid. Issues (Important): Magic number (100)

[Implementer fixes]
Implementer: Extracted PROGRESS_INTERVAL constant

[Code reviewer reviews again]
Code reviewer: ✅ Approved

[Mark Task 2 complete]

...

[After all tasks]
[Dispatch final code quality review]
Final reviewer: All requirements met, ready to merge

Done!
```

## Advantages

**vs. Manual execution:**
- Subagents follow TDD naturally
- Fresh context per task (no confusion)
- Parallel-safe (subagents don't interfere)
- Subagent can ask questions (before AND during work)

**vs. batch execution:**
- Same session (no handoff)
- Continuous progress (no waiting)
- Review checkpoints automatic

**Efficiency gains:**
- No file reading overhead (controller provides full text)
- Controller curates exactly what context is needed
- Subagent gets complete information upfront
- Questions surfaced before work begins (not after)

**Quality gates:**
- Self-review catches issues before handoff
- Two-stage review: spec compliance, then code quality
- Review loops ensure fixes actually work
- Spec compliance prevents over/under-building
- Code quality ensures implementation is well-built

**Cost:**
- More subagent invocations (implementer + 2 reviewers per task)
- Controller does more prep work (extracting all tasks upfront)
- Review loops add iterations
- But catches issues early (cheaper than debugging later)

## Red Flags

**Never:**
- Start implementation on main/master branch without explicit user consent
- Skip reviews (spec compliance OR code quality)
- Proceed with unfixed issues
- Dispatch multiple implementation subagents in parallel (conflicts)
- Make subagent read plan file (provide full text instead)
- Skip scene-setting context (subagent needs to understand where task fits)
- Ignore subagent questions (answer before letting them proceed)
- Accept "close enough" on spec compliance (spec reviewer found issues = not done)
- Skip review loops (reviewer found issues = implementer fixes = review again)
- Let implementer self-review replace actual review (both are needed)
- **Start code quality review before spec compliance is ✅** (wrong order)
- Move to next task while either review has open issues

**If subagent asks questions:**
- Answer clearly and completely
- Provide additional context if needed
- Don't rush them into implementation

**If reviewer finds issues:**
- Implementer (same subagent) fixes them
- Reviewer reviews again
- Repeat until approved
- Don't skip the re-review

**If subagent fails task:**
- Dispatch fix subagent with specific instructions
- Don't try to fix manually (context pollution)
