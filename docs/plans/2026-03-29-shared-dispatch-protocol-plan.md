# Shared Dispatch Protocol Extraction — Implementation Plan

**Goal:** Replace duplicated subagent dispatch protocol and finish phase in build-feature.md and execute-plan.md with skill references.

**Architecture:** Two file edits. Replace inline 7-step protocol with subagent-driven-development skill load + agent routing. Replace inline finish steps with skill load only (same pattern applied to finish-branch.md in prior task).

**Tech Stack:** Markdown

**Design doc:** `docs/plans/2026-03-29-shared-dispatch-protocol-design.md`

---

### Task 1: Deduplicate build-feature.md

**Files:**
- Modify: `external/opencode/commands/build-feature.md:38-52,64-73`

**Step 1: Replace subagent-driven section**

Replace lines 38-52 (the `### IF subagent-driven (choice A):` section including the 7-step protocol, error handling, and final review) with:

```markdown
### IF subagent-driven (choice A):

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review
```

**Step 2: Replace finish phase inline steps**

Replace lines 64-73 (Phase 5) with:

```markdown
## Phase 5 — Finish.

Load the finishing-a-development-branch skill and follow it.
```

The inline steps 1-5 are duplicated from the skill (same fix as finish-branch.md, task #6).

**Step 3: Verify the file**

- Subagent-driven section references skill + names agents
- No inline 7-step protocol remains
- TDD directive (line 36) is preserved above the subagent section
- Batch section (lines 54-62) is unchanged
- Finish phase has no inline steps

**Step 4: Commit**

```bash
git add external/opencode/commands/build-feature.md
git commit -m "deduplicate build-feature.md: load skills instead of inlining

Replace inline subagent dispatch protocol with subagent-driven-development
skill reference + agent routing. Replace inline finish steps with skill
load only."
```

---

### Task 2: Deduplicate execute-plan.md

**Files:**
- Modify: `external/opencode/commands/execute-plan.md:28-42,63-72`

**Step 1: Replace subagent-driven section**

Replace lines 28-42 (the `### IF subagent-driven (choice A):` section including the 7-step protocol, error handling, and final review) with:

```markdown
### IF subagent-driven (choice A):

Load the subagent-driven-development skill and follow it. Use these agents:
- task-implementer for implementation
- spec-reviewer for spec compliance verification
- code-reviewer for code quality review
```

**Step 2: Replace finish phase inline steps**

Replace lines 63-72 (Phase 3) with:

```markdown
## Phase 3 — Finish.

Load the finishing-a-development-branch skill and follow it.
```

**Step 3: Verify the file**

- Subagent-driven section references skill + names agents
- No inline 7-step protocol remains
- TDD directive (line 26) is preserved above the subagent section
- Batch section (lines 44-52) is unchanged
- STOP conditions (lines 54-61) are unchanged
- Finish phase has no inline steps

**Step 4: Commit**

```bash
git add external/opencode/commands/execute-plan.md
git commit -m "deduplicate execute-plan.md: load skills instead of inlining

Replace inline subagent dispatch protocol with subagent-driven-development
skill reference + agent routing. Replace inline finish steps with skill
load only."
```
