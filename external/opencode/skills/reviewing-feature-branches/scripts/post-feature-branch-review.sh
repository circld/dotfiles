#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf '%s\n' \
		"Usage: $0 --review-json <file> [--template <file>] [--pr <number>] [--dry-run]"
}

check_deps() {
	for cmd in jq; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			printf "ERROR - required tool '%s' not found\n" "$cmd" >&2
			exit 1
		fi
	done
}

REVIEW_JSON=""
TEMPLATE="external/opencode/skills/reviewing-feature-branches/pr-comment-template.md"
PR_NUMBER=""
DRY_RUN=0
KEEP_RENDERED_FILE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--review-json)
		REVIEW_JSON="$2"
		shift 2
		;;
	--template)
		TEMPLATE="$2"
		shift 2
		;;
	--pr)
		PR_NUMBER="$2"
		shift 2
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

[[ "$DRY_RUN" -eq 0 || -n "$PR_NUMBER" ]] || {
	printf 'ERROR - --pr is required in dry-run render mode\n' >&2
	exit 1
}

check_deps

RENDERED_FILE="$(mktemp /tmp/feature-branch-review-XXXX.md)"
cleanup() {
	if [[ "$KEEP_RENDERED_FILE" -eq 0 ]]; then
		rm -f "$RENDERED_FILE"
	fi
}
trap cleanup EXIT

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

if [[ "$DRY_RUN" -eq 1 ]]; then
	printf 'Rendered review for PR #%s to %s\n' "$PR_NUMBER" "$RENDERED_FILE"
	exit 0
fi

printf 'ERROR - post mode is not implemented yet\n' >&2
exit 1
