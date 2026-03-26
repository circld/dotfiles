#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/external/opencode/skills/reviewing-feature-branches/scripts/post-feature-branch-review.sh"

assert_missing_value() {
	local option="$1"
	local output
	local rc

	set +e
	output="$({
		"$SCRIPT" "$option"
	} 2>&1)"
	rc=$?
	set -e

	test "$rc" -eq 2
	test "$output" = "ERROR - missing value for $option
Usage: $SCRIPT --review-json <file> [--template <file>] [--pr <number>] [--dry-run]"
}

assert_missing_value --review-json
assert_missing_value --template
assert_missing_value --pr
