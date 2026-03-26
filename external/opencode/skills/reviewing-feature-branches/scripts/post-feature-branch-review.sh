#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf '%s\n' \
		"Usage: $0 --review-json <file> [--template <file>] [--pr <number>] [--edit] [--dry-run]"
}

missing_option_value() {
	local option="$1"

	printf 'ERROR - missing value for %s\n' "$option" >&2
	usage >&2
	exit 2
}

check_deps() {
	for cmd in gh jq; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			printf "ERROR - required tool '%s' not found\n" "$cmd" >&2
			exit 1
		fi
	done
}

detect_pr_number() {
	gh pr view --json number --jq '.number'
}

render_comment() {
	local rendered_content

	rendered_content="$({
		jq -rRn \
			--rawfile template "$TEMPLATE" \
			--slurpfile review "$REVIEW_JSON" '
    def required($obj; $key):
      if ($obj[$key] // "") == "" then
        error("Missing required field: " + $key)
      else
        $obj[$key]
      end;

    ($review[0]) as $r
    | {
        "\\{VERDICT\\}": required($r; "verdict"),
        "\\{READY_TO_MERGE\\}": required($r; "ready_to_merge"),
        "\\{VERDICT_REASONING\\}": required($r; "reasoning"),
        "\\{OBJECTIVE_ASSESSMENT\\}": required($r; "objective_assessment"),
        "\\{ENGINEERING_ISSUES\\}": required($r; "engineering_issues"),
        "\\{SECURITY_ISSUES\\}": ($r.security_issues // "None."),
        "\\{SCOPE_ASSESSMENT\\}": required($r; "scope_assessment")
      } as $replacements
    | reduce ($replacements | to_entries[]) as $entry
        ($template; gsub($entry.key; $entry.value))
	    '
	})"

	printf '%s\n' "$rendered_content" >"$RENDERED_FILE"
}

REVIEW_JSON=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../pr-comment-template.md"
PR_NUMBER=""
EDIT=0
DRY_RUN=0
KEEP_RENDERED_FILE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--review-json)
		[[ $# -ge 2 && "$2" != --* ]] || missing_option_value "$1"
		REVIEW_JSON="$2"
		shift 2
		;;
	--template)
		[[ $# -ge 2 && "$2" != --* ]] || missing_option_value "$1"
		TEMPLATE="$2"
		shift 2
		;;
	--pr)
		[[ $# -ge 2 && "$2" != --* ]] || missing_option_value "$1"
		PR_NUMBER="$2"
		shift 2
		;;
	--edit)
		EDIT=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		KEEP_RENDERED_FILE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		printf 'ERROR - unknown arg: %s\n' "$1" >&2
		usage
		exit 2
		;;
	esac
done

[[ -n "$REVIEW_JSON" ]] || {
	usage
	exit 2
}

[[ -f "$REVIEW_JSON" ]] || {
	printf 'ERROR - missing review JSON: %s\n' "$REVIEW_JSON" >&2
	exit 1
}

[[ -f "$TEMPLATE" ]] || {
	printf 'ERROR - missing template: %s\n' "$TEMPLATE" >&2
	exit 1
}

check_deps

if [[ -z "$PR_NUMBER" ]]; then
	PR_NUMBER="$(detect_pr_number)"
fi

[[ -n "$PR_NUMBER" ]] || {
	printf 'ERROR - could not determine PR number\n' >&2
	exit 1
}

RENDERED_FILE="$(mktemp /tmp/feature-branch-review-XXXX.md)"
cleanup() {
	if [[ "$KEEP_RENDERED_FILE" -eq 0 ]]; then
		rm -f "$RENDERED_FILE"
	fi
}
trap cleanup EXIT

render_comment

if [[ "$EDIT" -eq 1 ]]; then
	"${EDITOR:-vim}" "$RENDERED_FILE"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'Rendered review for PR #%s to %s\n' "$PR_NUMBER" "$RENDERED_FILE"
	exit 0
fi

gh pr comment "$PR_NUMBER" --body-file "$RENDERED_FILE"
printf 'Posted review to PR #%s\n' "$PR_NUMBER"
