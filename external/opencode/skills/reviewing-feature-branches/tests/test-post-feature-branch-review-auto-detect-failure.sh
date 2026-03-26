#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/external/opencode/skills/reviewing-feature-branches/scripts/post-feature-branch-review.sh"
REVIEW_JSON="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/review.json"
TEMPLATE="$ROOT/external/opencode/skills/reviewing-feature-branches/pr-comment-template.md"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'no pull request found for branch\n' >&2
exit 1
EOF
chmod +x "$TMP_DIR/bin/gh"

set +e
OUTPUT="$({
	PATH="$TMP_DIR/bin:$PATH" \
		"$SCRIPT" \
		--review-json "$REVIEW_JSON" \
		--template "$TEMPLATE" \
		--dry-run
} 2>&1)"
RC=$?
set -e

test "$RC" -eq 1
test "$OUTPUT" = 'ERROR - could not determine PR number; pass --pr <number> or run this from a branch with an open PR'
