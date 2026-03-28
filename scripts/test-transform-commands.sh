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
    PASS=$((PASS + 1))
  else
    echo "FAIL: $test_name"
    echo "  expected:"
    echo "$expected" | sed 's/^/    /'
    echo "  actual:"
    echo "$actual" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
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
