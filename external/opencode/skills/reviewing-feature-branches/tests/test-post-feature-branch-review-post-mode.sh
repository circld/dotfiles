#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/external/opencode/skills/reviewing-feature-branches/scripts/post-feature-branch-review.sh"
REVIEW_JSON="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/review.json"
TEMPLATE="$ROOT/external/opencode/skills/reviewing-feature-branches/pr-comment-template.md"

set +e
OUTPUT="$({
	"$SCRIPT" \
		--review-json "$REVIEW_JSON" \
		--template "$TEMPLATE"
} 2>&1)"
RC=$?
set -e

test "$RC" -eq 1
test "$OUTPUT" = 'ERROR - post mode is not implemented yet'
