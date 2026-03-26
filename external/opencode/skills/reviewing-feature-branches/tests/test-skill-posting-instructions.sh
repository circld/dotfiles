#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SKILL="$ROOT/external/opencode/skills/reviewing-feature-branches/SKILL.md"

SECTION="$({
	awk '
    /^\*\*5\. Post review to PR \(optional\):\*\*$/ { capture = 1 }
    /^## Integration$/ { capture = 0 }
    capture { print }
  ' "$SKILL"
})"

printf '%s\n' "$SECTION" | grep -F 'scripts/post-feature-branch-review.sh --review-json' >/dev/null
printf '%s\n' "$SECTION" | grep -F 'scripts/post-feature-branch-review.sh --review-json /tmp/review.json --edit' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `verdict`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `ready_to_merge`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `reasoning`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `objective_assessment`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `engineering_issues`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `security_issues`' >/dev/null
printf '%s\n' "$SECTION" | grep -F -- '- `scope_assessment`' >/dev/null
printf '%s\n' "$SECTION" | grep -F 'Use `--pr <number>` when auto-detect is unavailable.' >/dev/null
printf '%s\n' "$SECTION" | grep -F 'Use `--dry-run` to preview the rendered comment without posting.' >/dev/null

LINES="$(printf '%s\n' "$SECTION" | wc -l | tr -d ' ')"
[[ "$LINES" -le 20 ]]

if printf '%s\n' "$SECTION" | grep -F 'gh pr comment $PR_NUMBER --body-file "$REVIEW_FILE"' >/dev/null; then
	printf 'manual gh posting command still present\n' >&2
	exit 1
fi

if printf '%s\n' "$SECTION" | grep -F 'REVIEW_FILE=$(mktemp /tmp/pr-review-XXXX.md)' >/dev/null; then
	printf 'manual temp-file instruction still present\n' >&2
	exit 1
fi
