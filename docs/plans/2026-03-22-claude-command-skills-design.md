# Cross-Client Command Sharing: Claude Code Command-Skills

## Problem

OpenCode separates commands (orchestration/coordination) from skills (capabilities/knowledge). Claude Code collapses both into a single `skills/` namespace. The dotfiles currently maintain separate `external/claude/commands/` and `external/opencode/commands/` directories with different content and formats.

## Design

### Naming Convention

Commands deployed to Claude Code's skills directory use a `cmd-` prefix to preserve the conceptual distinction:

- `/cmd-build-feature` — orchestration command
- `/cmd-debug` — orchestration command
- `/brainstorming` — knowledge/capability skill

### Nix Derivation: `claudeCommandSkills`

A self-discovering derivation that:

1. Reads all `.md` files from `external/opencode/commands/`
2. Transforms each into a Claude Code skill directory (`cmd-<name>/SKILL.md`)
3. Outputs a single directory with all transformed command-skills

**Transformation per file:**

1. Strip `arguments:` block from YAML frontmatter (OpenCode-specific)
2. Rewrite `name: X` to `name: cmd-X`
3. Replace all `{{anything}}` template variables with `$ARGUMENTS` in the body

**Example input** (`build-feature.md`):

```yaml
---
name: build-feature
description: Implement a feature end-to-end...
arguments:
  - name: description
    description: What to build
    required: true
---

Build the following feature: {{description}}
```

**Example output** (`cmd-build-feature/SKILL.md`):

```yaml
---
name: cmd-build-feature
description: Implement a feature end-to-end...
---

Build the following feature: $ARGUMENTS
```

### Wiring in `common.nix`

Because `.claude/skills` was previously symlinked as a whole directory, and we now need to merge store-built command-skills alongside live-symlinked skills, both must be wired as individual entries.

**Self-discovering skill entries** — reads `external/opencode/skills/`, creates one `mkOutOfStoreSymlink` per skill directory. Edits are live (no `home-manager switch` needed).

**Self-discovering command entries** — reads `external/opencode/commands/`, creates one store-path link per command from the derivation output. Edits require `home-manager switch` (acceptable — orchestration logic changes infrequently).

```nix
let
  # Discover skills
  skillsDir = ../external/opencode/skills;
  skillNames = builtins.attrNames (builtins.readDir skillsDir);
  claudeSkillEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/${name}";
    value = { source = ln "external/opencode/skills/${name}"; };
  }) skillNames);

  # Discover and transform commands
  commandsDir = ../external/opencode/commands;
  commandFiles = builtins.filter (f: builtins.match ".*\\.md$" f != null)
    (builtins.attrNames (builtins.readDir commandsDir));
  commandNames = map (f: builtins.replaceStrings [ ".md" ] [ "" ] f) commandFiles;

  claudeCommandSkills = pkgs.runCommand "claude-command-skills" {} ''
    mkdir -p $out
    for file in ${commandsDir}/*.md; do
      basename=$(basename "$file" .md)
      mkdir -p "$out/cmd-$basename"
      ${pkgs.gawk}/bin/awk '
        BEGIN { in_front=0; in_args=0; past_front=0 }
        /^---$/ && !in_front && !past_front { in_front=1; print; next }
        /^---$/ && in_front { in_front=0; past_front=1; in_args=0; print; next }
        in_front && /^arguments:/ { in_args=1; next }
        in_front && in_args && /^[[:space:]]/ { next }
        in_front && in_args && !/^[[:space:]]/ { in_args=0 }
        in_front && /^name:/ { sub(/^name: /, "name: cmd-"); print; next }
        in_front { print; next }
        past_front { gsub(/\{\{[^}]+\}\}/, "$ARGUMENTS"); print }
      ' "$file" > "$out/cmd-$basename/SKILL.md"
    done
  '';

  claudeCommandEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/cmd-${name}";
    value = { source = "${claudeCommandSkills}/cmd-${name}"; };
  }) commandNames);
in
{
  home.file = {
    ".claude/agents".source = ln "external/opencode/agents";
    ".claude/CLAUDE.md".source = ln "external/opencode/AGENTS.md";
    # ... other dotfiles ...
  } // claudeSkillEntries // claudeCommandEntries;
}
```

### Files Changed

**Modified:**
- `modules/common.nix` — replace directory-level `.claude/skills` and `.claude/commands` symlinks with self-discovering individual entries; point `.claude/CLAUDE.md` and `.claude/agents` to `external/opencode/`

**Removed (after verification):**
- `external/claude/CLAUDE.md`
- `external/claude/commands/` (3 old-style files)
- `external/claude/agents/` (7 old-style files)

### Trade-offs

- Commands require `home-manager switch` after edits (skills remain live via symlinks)
- Adding a new command or skill requires `home-manager switch` to create the new symlink entry
- The `cmd-` prefix is visible in Claude's `/` command UI — this is intentional, not a limitation
- Cross-references between commands (e.g., `write-plan.md` references `/execute-plan`) will appear as `/execute-plan` in the body but the skill is registered as `/cmd-execute-plan` — Claude will need to resolve this contextually

### Open Questions

1. Does OpenCode ignore unknown frontmatter keys if agents gain `tools`/`model` fields?
2. Do cross-references like "invoke `/execute-plan`" need updating to `/cmd-execute-plan` in command bodies, or will Claude resolve them contextually?
