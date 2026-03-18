#!/usr/bin/env bash
set -euo pipefail

# Usage: reply-and-resolve.sh <id> <type> <pr-number> <body>
#
# type: inline-fix | inline-flag | top-level-fix | top-level-flag
#
# inline-fix:      reply to thread + resolve
# inline-flag:     reply to thread only
# top-level-fix:   post PR comment
# top-level-flag:  post PR comment

usage() {
	echo "Usage: $0 <id> <type> <pr-number> <body>" >&2
	echo "  type: inline-fix | inline-flag | top-level-fix | top-level-flag" >&2
	exit 1
}

check_deps() {
	for cmd in gh; do
		if ! command -v "$cmd" &>/dev/null; then
			echo "ERROR — required tool '$cmd' not found" >&2
			exit 1
		fi
	done
}

reply_to_thread() {
	local thread_id="$1" body="$2"

	gh api graphql \
		-f query='
      mutation($threadId: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: {
          pullRequestReviewThreadId: $threadId,
          body: $body
        }) {
          comment { id }
        }
      }
    ' \
		-f threadId="$thread_id" \
		-f body="$body" \
		>/dev/null 2>"$err_file" || {
		echo "ERROR — reply failed: $(cat "$err_file")" >&2
		exit 1
	}
}

resolve_thread() {
	local thread_id="$1"

	gh api graphql \
		-f query='
      mutation($threadId: ID!) {
        resolveReviewThread(input: {threadId: $threadId}) {
          thread { isResolved }
        }
      }
    ' \
		-f threadId="$thread_id" \
		>/dev/null 2>"$err_file" || {
		echo "ERROR — resolve failed: $(cat "$err_file")" >&2
		exit 1
	}
}

comment_on_pr() {
	local pr_number="$1" body="$2"

	gh pr comment "$pr_number" --body "$body" >/dev/null 2>"$err_file" || {
		echo "ERROR — PR comment failed: $(cat "$err_file")" >&2
		exit 1
	}
}

main() {
	[[ $# -ne 4 ]] && usage
	check_deps

	local id="$1"
	local type="$2"
	local pr_number="$3"
	local body="$4"

	err_file=$(mktemp)
	trap 'rm -f "$err_file"' EXIT

	case "$type" in
	inline-fix)
		reply_to_thread "$id" "$body"
		resolve_thread "$id"
		echo "OK — replied and resolved"
		;;
	inline-flag)
		reply_to_thread "$id" "$body"
		echo "OK — replied"
		;;
	top-level-fix | top-level-flag)
		comment_on_pr "$pr_number" "$body"
		echo "OK — replied"
		;;
	*)
		echo "ERROR — unknown type '$type'. Expected: inline-fix, inline-flag, top-level-fix, top-level-flag" >&2
		exit 1
		;;
	esac
}

main "$@"
