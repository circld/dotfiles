---
name: brainstorming
description: "Use when the user requests new functionality, changes to existing behavior, or any task where the intent, scope, or approach is not fully obvious from the request. Err on the side of invoking -- brief unnecessary clarification is cheaper than building the wrong thing. Not for purely mechanical tasks like renaming, reformatting, or running commands."
---

# Brainstorming Ideas Into Designs

## When to Use

- User requests new functionality or changes to existing behavior
- Intent, scope, or approach is ambiguous or underspecified
- Err toward using this workflow -- unnecessary clarification is cheaper than building the wrong thing

## When Not to Use

- Purely mechanical tasks: renaming, reformatting, running commands
- The request is fully specified with no ambiguity
- Implementation is already underway and the design is settled

## Workflow Constraints

Dialogue-only workflow. Output: a validated design, not code or file changes. Never modify project files, run build commands, or produce implementation artifacts yourself. Refinement happens through questions and conversation. Verify assumptions by reading code, docs, and config first. Whatever still needs execution is verified by probing -- delegated to an execution-capable subagent when available, else written as a probe spec for the user to run.

## The Process

**Understanding the idea:**
- Review available project context to understand the current state
- Ask questions one at a time to refine the idea
- Prefer multiple choice questions when possible
- Only one question per message -- break complex topics into multiple questions
- Focus on understanding: purpose, constraints, success criteria

**Exploring approaches:**
- Propose 2-3 different approaches with trade-offs
- Lead with your recommended option and explain why
- Present options conversationally

**Verifying assumptions (before presenting the design):**
- A load-bearing assumption is a claim about the solution space -- API or library behavior, data shape, platform capability, performance -- where if false, the design collapses or materially changes
- List the load-bearing assumptions behind the recommended approach, including "obvious" ones -- a confident wrong belief is the dangerous case
- Settle what you can by reading: code, docs, config. Probes are only for assumptions reading cannot settle
- For each remaining assumption, write a probe spec (exact command or steps, expected outcomes, design meaning per outcome) and get it executed -- delegate to an execution-capable subagent when available, else hand it to the user to run and paste back results
- Gate: no validated design until every load-bearing assumption carries evidence -- read or probed. Skip only by flagging unverified risk with explicit user acceptance

**Presenting the design:**
- Begin with verified assumptions and their evidence; end with unverified risks
- Present the design in sections of 200-300 words
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Go back and clarify if something doesn't make sense

## Key Principles

- **One question at a time** -- do not overwhelm with multiple questions
- **Multiple choice preferred** -- easier to answer than open-ended
- **YAGNI ruthlessly** -- remove unnecessary features from all designs
- **Explore alternatives** -- always propose 2-3 approaches before settling
- **Incremental validation** -- present design in sections, validate each
- **Evidence before commitment** -- verify load-bearing assumptions empirically before committing to a design

## Red Flags -- STOP and Verify

- "X probably supports this" / "this should work" / "assuming the data looks like..."
- Asserting tool versions, auth state, or API behavior you did not just read or probe

All of these mean: verify by reading, verify by probe, or flag as unverified risk.
