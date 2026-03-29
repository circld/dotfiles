# Design: Extract Shared Dispatch Protocol from build-feature/execute-plan

## Problem

`build-feature.md` and `execute-plan.md` both inline a nearly identical 7-step subagent dispatch protocol (implement → spec review → code review, with fix loops). The `subagent-driven-development` skill already encodes this exact process as domain knowledge, including the flowchart, example workflow, red flags, and error handling rules. The commands duplicate the skill rather than loading it.

## Design

Replace the inline subagent-driven sections in both commands with a skill reference plus agent routing.

### build-feature.md Phase 4, subagent-driven section

Replace the current 7-step protocol (lines 40-52) with:

```markdown
### IF subagent-driven (choice A):

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review
```

### execute-plan.md Phase 2, subagent-driven section

Replace the current 7-step protocol (lines 30-42) with:

```markdown
### IF subagent-driven (choice A):

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review
```

### What stays in the commands

- Execution mode choice (A vs B) — command-level orchestration
- TDD directive ("task-implementer must follow TDD methodology") — constraint the command adds
- Batch mode section — references the executing-plans skill (separate concern)
- STOP conditions (execute-plan only) — command-level safety
- Finish phase — references the finishing-a-development-branch skill
- Agent name routing — commands are allowed to reference agents per the spec

### What moves to the skill (already there)

- Sequential task dispatch (never parallel)
- Per-task cycle: implement → spec review → code review with fix loops
- Context provision rules (provide full text, don't make subagent read plan)
- Failed task handling (new subagent, don't fix manually)
- Final code review after all tasks
- Red flags and error handling

### Finish phase duplication

Both commands also duplicate the finish phase (load finishing-a-development-branch skill, then inline steps 1-5). `finish-branch.md` was already fixed (task #6) by removing its inline duplication. The same fix applies here: replace the inline steps with just the skill load directive.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Extract new skill? | No — skill already exists | subagent-driven-development covers the exact protocol |
| Agent names | Stay in commands | Commands route to agents per spec; skill uses domain language |
| Finish phase | Also deduplicate | Same pattern as finish-branch.md fix (task #6) |
| Skill context cost (223 lines) | Acceptable | Red Flags and example workflow are valuable; nothing harmful |
