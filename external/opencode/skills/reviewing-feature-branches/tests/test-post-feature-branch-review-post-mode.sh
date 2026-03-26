#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/external/opencode/skills/reviewing-feature-branches/scripts/post-feature-branch-review.sh"
REVIEW_JSON="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/review.json"
TEMPLATE="$ROOT/external/opencode/skills/reviewing-feature-branches/pr-comment-template.md"
EXPECTED="$ROOT/external/opencode/skills/reviewing-feature-branches/tests/fixtures/expected-comment.md"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/logs"

cat >"$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1:$2" in
  pr:comment)
    cp "$5" "$GH_LOG_DIR/posted-comment.md"
    printf '%s\n' "$*" > "$GH_LOG_DIR/comment-command.txt"
    ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"

OUTPUT="$({
	PATH="$TMP_DIR/bin:$PATH" \
		GH_LOG_DIR="$TMP_DIR/logs" \
		"$SCRIPT" \
		--review-json "$REVIEW_JSON" \
		--template "$TEMPLATE" \
		--pr 456
} 2>&1)"

diff -u "$EXPECTED" "$TMP_DIR/logs/posted-comment.md"
grep -F 'Posted review to PR #456' <<<"$OUTPUT" >/dev/null
grep -F 'pr comment 456 --body-file' "$TMP_DIR/logs/comment-command.txt" >/dev/null
