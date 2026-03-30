---
name: brainstorm
description: Explore an idea through collaborative dialogue to clarify intent and produce a validated design.
arguments:
  - name: description
    description: The idea to explore
    required: true
---

Explore the following idea: {{description}}

Load the brainstorming skill and follow it. This command produces a validated design only — no implementation.

If the design is validated, ask: "Should I write this up as a design doc?" If yes, write to docs/plans/YYYY-MM-DD-<topic>-design.md and commit.
