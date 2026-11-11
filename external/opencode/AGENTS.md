# external/opencode — agentic tooling

AI tool config for opencode.

## Edit propagation

- **Content edits**: live immediately.
- **Add/remove a directory** (skills, commands, agents): live immediately.

## Authoring reference

`docs/agentic-component-spec.md` is the canonical reference for skill/command/agent structure.

## Gitignore

`ol-*` directories (e.g., `skills/ol-sonar/`) are gitignored — work-specific components.

## instructions.md

This directory's `instructions.md` is the AI behavior file loaded as system instructions
by OpenCode via symlink. It is **not** this file.
