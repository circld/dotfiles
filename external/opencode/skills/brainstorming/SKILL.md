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

This is a dialogue-only workflow. The output is a validated design, not code or file changes. Do not modify project files, run build commands, or produce implementation artifacts. All refinement happens through questions and conversation.

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

**Presenting the design:**
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
