# Claude Command-Skills Implementation Plan

**Goal:** Wire OpenCode commands into Claude Code's skills directory as `cmd-`-prefixed skills via a Nix derivation that transforms frontmatter and template syntax.

**Architecture:** A `runCommand` derivation runs an awk script over `external/opencode/commands/*.md`, producing `cmd-<name>/SKILL.md` directories. Nix evaluation-time discovery generates `home.file` entries for both skills (live symlinks) and command-skills (store paths). Replaces the current split between `external/claude/` and `external/opencode/`.

**Tech Stack:** Nix (home-manager), gawk, shell (test script)

---

### Task 1: Write the awk transformation test script

**Files:**
- Create: `scripts/test-transform-commands.sh`

**Step 1: Create the test script with test cases**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWK_SCRIPT="$SCRIPT_DIR/transform-command-to-skill.awk"
PASS=0
FAIL=0

assert_output() {
  local test_name="$1"
  local input="$2"
  local expected="$3"
  local actual
  actual=$(echo "$input" | awk -f "$AWK_SCRIPT")
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $test_name"
    ((PASS++))
  else
    echo "FAIL: $test_name"
    echo "  expected:"
    echo "$expected" | sed 's/^/    /'
    echo "  actual:"
    echo "$actual" | sed 's/^/    /'
    ((FAIL++))
  fi
}

# Test 1: Strips arguments block and prefixes name
assert_output "strips arguments and prefixes name" \
'---
name: build-feature
description: Implement a feature end-to-end.
arguments:
  - name: description
    description: What to build
    required: true
---

Build the following feature: {{description}}' \
'---
name: cmd-build-feature
description: Implement a feature end-to-end.
---

Build the following feature: $ARGUMENTS'

# Test 2: Empty arguments list
assert_output "handles empty arguments list" \
'---
name: finish-branch
description: Wrap up development work.
arguments: []
---

Wrap up the current development work.' \
'---
name: cmd-finish-branch
description: Wrap up development work.
---

Wrap up the current development work.'

# Test 3: No template variables in body
assert_output "handles no template variables" \
'---
name: finish-branch
description: Wrap up.
arguments: []
---

Load the skill and follow it.' \
'---
name: cmd-finish-branch
description: Wrap up.
---

Load the skill and follow it.'

# Test 4: Multiple template variables collapse to $ARGUMENTS
assert_output "multiple template vars become ARGUMENTS" \
'---
name: test-cmd
description: Test.
---

First: {{foo}} and second: {{bar}}' \
'---
name: cmd-test-cmd
description: Test.
---

First: $ARGUMENTS and second: $ARGUMENTS'

# Test 5: No arguments key at all
assert_output "handles missing arguments key" \
'---
name: simple
description: Simple command.
---

Do the thing: {{input}}' \
'---
name: cmd-simple
description: Simple command.
---

Do the thing: $ARGUMENTS'

# Test 6: Multi-line description preserved
assert_output "preserves multi-line description" \
'---
name: test-cmd
description: >
  A long description
  that spans lines.
arguments:
  - name: x
    description: thing
    required: true
---

Do: {{x}}' \
'---
name: cmd-test-cmd
description: >
  A long description
  that spans lines.
---

Do: $ARGUMENTS'

# Test 7: Template vars not replaced inside frontmatter
assert_output "template vars only replaced in body" \
'---
name: test-cmd
description: Handles {{things}} in description.
---

Body: {{input}}' \
'---
name: cmd-test-cmd
description: Handles {{things}} in description.
---

Body: $ARGUMENTS'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

**Step 2: Run test to verify it fails**

Run: `bash scripts/test-transform-commands.sh`
Expected: FAIL — awk script does not exist yet

---

### Task 2: Write the awk transformation script

**Files:**
- Create: `scripts/transform-command-to-skill.awk`

**Step 1: Write the awk script**

```awk
BEGIN {
  in_front = 0
  in_args = 0
  past_front = 0
}

# First --- opens frontmatter
/^---$/ && !in_front && !past_front {
  in_front = 1
  print
  next
}

# Second --- closes frontmatter
/^---$/ && in_front {
  in_front = 0
  past_front = 1
  in_args = 0
  print
  next
}

# Inside frontmatter: skip arguments block
in_front && /^arguments:/ {
  in_args = 1
  next
}

# Inside arguments block: skip indented lines (nested YAML)
in_front && in_args && /^[[:space:]]/ {
  next
}

# Inside arguments block: non-indented line ends the block
in_front && in_args && !/^[[:space:]]/ {
  in_args = 0
}

# Inside frontmatter: prefix name
in_front && /^name: / {
  sub(/^name: /, "name: cmd-")
  print
  next
}

# Inside frontmatter: pass through other fields
in_front {
  print
  next
}

# Body: replace template variables
past_front {
  gsub(/\{\{[^}]+\}\}/, "$ARGUMENTS")
  print
}
```

**Step 2: Run tests to verify they pass**

Run: `bash scripts/test-transform-commands.sh`
Expected: All 7 tests PASS

**Step 3: Run against real command files to verify output**

Run: `for f in external/opencode/commands/*.md; do echo "=== $(basename $f) ==="; awk -f scripts/transform-command-to-skill.awk "$f"; echo; done`
Expected: Each file transformed correctly — no arguments block, cmd- prefix, $ARGUMENTS in body

**Step 4: Commit**

```bash
git add scripts/transform-command-to-skill.awk scripts/test-transform-commands.sh
git commit -m "add awk script to transform opencode commands into claude skills"
```

---

### Task 3: Update `modules/common.nix`

**Files:**
- Modify: `modules/common.nix:2-6` (let bindings)
- Modify: `modules/common.nix:44-52` (home.file block)

**Step 1: Add skill and command discovery to the let block**

After the existing `unstablePkgs` binding, add:

```nix
  # Discover OpenCode skills for individual symlinking to Claude
  skillsDir = ../external/opencode/skills;
  skillNames = builtins.attrNames (builtins.readDir skillsDir);
  claudeSkillEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/${name}";
    value = { source = ln "external/opencode/skills/${name}"; };
  }) skillNames);

  # Discover and transform OpenCode commands into Claude cmd-prefixed skills
  commandsDir = ../external/opencode/commands;
  commandFiles = builtins.filter (f: builtins.match ".*\\.md$" f != null)
    (builtins.attrNames (builtins.readDir commandsDir));
  commandNames = map (f: builtins.replaceStrings [ ".md" ] [ "" ] f) commandFiles;

  claudeCommandSkills = pkgs.runCommand "claude-command-skills" { } ''
    mkdir -p $out
    for file in ${commandsDir}/*.md; do
      basename=$(basename "$file" .md)
      mkdir -p "$out/cmd-$basename"
      ${pkgs.gawk}/bin/awk -f ${../scripts/transform-command-to-skill.awk} \
        "$file" > "$out/cmd-$basename/SKILL.md"
    done
  '';

  claudeCommandEntries = builtins.listToAttrs (map (name: {
    name = ".claude/skills/cmd-${name}";
    value = { source = "${claudeCommandSkills}/cmd-${name}"; };
  }) commandNames);
```

**Step 2: Update the home.file block**

Replace the existing `.claude/*` entries:

```nix
  home.file = {
    ".claude/agents".source = ln "external/opencode/agents";
    ".claude/CLAUDE.md".source = ln "external/opencode/AGENTS.md";
    ".lua-format".source = ln "external/lua/.lua-format";
    ".yamlfmt".source = ln "external/yaml/.yamlfmt";
    ".zprofile".source = ln "external/zsh/.zprofile";
  } // claudeSkillEntries // claudeCommandEntries;
```

Removed:
- `.claude/commands` entry (replaced by claudeCommandEntries)
- `.claude/skills` directory entry (replaced by claudeSkillEntries)

Changed:
- `.claude/agents` source: `external/claude/agents` → `external/opencode/agents`
- `.claude/CLAUDE.md` source: `external/claude/CLAUDE.md` → `external/opencode/AGENTS.md`

**Step 3: Verify Nix evaluation succeeds**

Run: `nix-instantiate --eval -E 'let pkgs = import <nixpkgs> {}; in builtins.attrNames (builtins.readDir ./external/opencode/commands)'`
Expected: List of command filenames including `.gitkeep` and `.md` files

**Step 4: Commit**

```bash
git add modules/common.nix
git commit -m "refactor: wire claude skills and commands from shared opencode source"
```

---

### Task 4: Verify with `home-manager switch`

**Step 1: Run home-manager switch**

Run: `home-manager switch`
Expected: Successful activation with no errors

**Step 2: Verify skill symlinks**

Run: `ls -la ~/.claude/skills/`
Expected: One symlink per skill directory (brainstorming, writing-plans, etc.) pointing to `~/dotfiles/external/opencode/skills/<name>`, plus one directory per command (cmd-build-feature, cmd-debug, etc.) pointing to nix store paths

**Step 3: Verify a transformed command-skill**

Run: `cat ~/.claude/skills/cmd-build-feature/SKILL.md`
Expected: Frontmatter with `name: cmd-build-feature`, no `arguments:` block, `$ARGUMENTS` in body instead of `{{description}}`

**Step 4: Verify agents and instructions symlinks**

Run: `ls -la ~/.claude/agents && head -5 ~/.claude/CLAUDE.md`
Expected: agents points to `~/dotfiles/external/opencode/agents`, CLAUDE.md content matches AGENTS.md

**Step 5: Verify no collision between skills and command-skills**

Run: `ls ~/.claude/skills/ | sort`
Expected: No duplicate names — all commands have `cmd-` prefix, no overlap with skill names

---

### Task 5: Cleanup

**Files:**
- Remove: `external/claude/CLAUDE.md`
- Remove: `external/claude/agents/architecture-diagrammer.md`
- Remove: `external/claude/agents/code-sketch-generator.md`
- Remove: `external/claude/agents/function-call-graph-generator.md`
- Remove: `external/claude/agents/function-graph-diff-visualizer.md`
- Remove: `external/claude/agents/requirements-analyst.md`
- Remove: `external/claude/agents/tdd-feature-implementer.md`
- Remove: `external/claude/agents/web-research-synthesizer.md`
- Remove: `external/claude/commands/augment-prompt.md`
- Remove: `external/claude/commands/build-feature.md`
- Remove: `external/claude/commands/explain-concept.md`

**Step 1: Remove vestigial files**

Run: `rm external/claude/CLAUDE.md && rm external/claude/agents/*.md && rm external/claude/commands/*.md`

**Step 2: Verify nothing references removed files**

Run: `grep -r "external/claude" modules/ external/`
Expected: No references to `external/claude/agents`, `external/claude/commands`, or `external/claude/CLAUDE.md`

**Step 3: Commit**

```bash
git add -u external/claude/
git commit -m "remove vestigial claude-specific agents, commands, and instructions"
```
