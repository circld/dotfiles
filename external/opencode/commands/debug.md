---
name: debug
description: Systematically investigate and fix a bug or unexpected behavior.
arguments:
  - name: issue
    description: Description of the bug or unexpected behavior
    required: false
---

Debug the following issue: {{issue}}

Load the systematic-debugging skill and follow it. Do not propose fixes until root cause is identified.

When creating a failing test case (Phase 4), follow TDD methodology — load the test-driven-development skill.
