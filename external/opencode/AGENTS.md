# external/opencode — agentic tooling

AI tool config for opencode and Claude Code.

## Edit propagation

- **Content edits**: live for both tools immediately.
- **Add/remove a directory** (skills, commands): requires `home-manager switch`.

## Agents: manual dual-maintenance

`external/opencode/agents/` and `external/claude/agents/` are **not** kept in sync by
any codegen. Edit both when changing agent body content. Frontmatter schemas differ by
tool — do not copy frontmatter between them.

## Commands → Claude skills (codegen)

Every `.md` in `commands/` is transformed by `scripts/transform-command-to-skill.awk`
at `home-manager build/switch` and symlinked to `~/.claude/skills/cmd-<name>/SKILL.md`.
Skills are **not** transformed — they are symlinked as-is.

## Authoring reference

`docs/agentic-component-spec.md` is the canonical reference for skill/command/agent structure.

## Gitignore

`ol-*` directories (e.g., `skills/ol-sonar/`) are gitignored — work-specific components.

## instructions.md

This directory's `instructions.md` is the AI behavior file loaded as system instructions
by both tools via symlink. It is **not** this file.
