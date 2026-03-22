---
name: write-skill
description: Create or edit an agentic skill using TDD methodology.
arguments:
  - name: skill_name
    description: Name of the skill to create or edit
    required: true
---

Create or edit a skill: {{skill_name}}

Load the writing-skills skill and follow it.

Follow the TDD cycle for skills:
1. RED — Write pressure scenarios. Dispatch a subagent WITHOUT the skill to establish baseline behavior. Document exact rationalizations and failures.
2. GREEN — Write the skill addressing those specific failures. Dispatch same scenarios WITH the skill. Verify compliance.
3. REFACTOR — Identify new loopholes. Add explicit counters. Re-test until bulletproof.

Track checklist progress throughout. Do not create multiple skills in batch — complete the full TDD cycle for each skill before starting the next.
