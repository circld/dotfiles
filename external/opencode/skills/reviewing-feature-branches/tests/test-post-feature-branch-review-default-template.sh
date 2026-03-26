#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/external/opencode/skills/reviewing-feature-branches/scripts/post-feature-branch-review.sh"
REVIEW_JSON="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/review.json"
EXPECTED="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/expected-comment.md"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh should not be called in render-only dry run\n' >&2
exit 99
EOF
chmod +x "$TMP_DIR/bin/gh"

OUTPUT="$({
	cd "$TMP_DIR"
	PATH="$TMP_DIR/bin:$PATH" \
		"$SCRIPT" \
		--review-json "$REVIEW_JSON" \
		--pr 123 \
		--dry-run
} 2>&1)"

RENDERED_FILE="${OUTPUT##* to }"

test -f "$RENDERED_FILE"
diff -u "$EXPECTED" "$RENDERED_FILE"
