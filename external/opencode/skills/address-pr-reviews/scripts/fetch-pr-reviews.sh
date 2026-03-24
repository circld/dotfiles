#!/usr/bin/env bash
set -euo pipefail

# Usage: fetch-pr-reviews.sh <owner> <repo> <pr-number>

usage() {
	echo "Usage: $0 <owner> <repo> <pr-number>" >&2
	exit 1
}

check_deps() {
	for cmd in gh jq; do
		if ! command -v "$cmd" &>/dev/null; then
			echo "ERROR — required tool '$cmd' not found" >&2
			exit 1
		fi
	done
}

fetch_page() {
	local owner="$1" repo="$2" pr_number="$3"
	local reviews_cursor="${4:-}" threads_cursor="${5:-}" comments_cursor="${6:-}"

	local reviews_after=""
	local threads_after=""
	local comments_after=""
	[[ -n "$reviews_cursor" ]] && reviews_after=", after: \"$reviews_cursor\""
	[[ -n "$threads_cursor" ]] && threads_after=", after: \"$threads_cursor\""
	[[ -n "$comments_cursor" ]] && comments_after=", after: \"$comments_cursor\""

	gh api graphql -f query="
    query {
      repository(owner: \"$owner\", name: \"$repo\") {
        pullRequest(number: $pr_number) {
          reviews(first: 50${reviews_after}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              state
              body
              author { login }
              comments(first: 50) {
                nodes { body path line }
              }
            }
          }
          reviewThreads(first: 50${threads_after}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              comments(last: 50) {
                nodes { body path line author { login } }
              }
            }
          }
          comments(first: 50${comments_after}) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              body
              author { login }
            }
          }
        }
      }
    }
  " 2>/tmp/fetch-pr-reviews-err || {
		echo "ERROR — GitHub API call failed: $(cat /tmp/fetch-pr-reviews-err)" >&2
		exit 1
	}
}

fetch_all() {
	local owner="$1" repo="$2" pr_number="$3"
	local reviews_cursor="" threads_cursor="" comments_cursor=""
	local all_reviews="[]" all_threads="[]" all_comments="[]"
	local has_more_reviews=true has_more_threads=true has_more_comments=true

	while [[ "$has_more_reviews" == "true" ]] || [[ "$has_more_threads" == "true" ]] || [[ "$has_more_comments" == "true" ]]; do
		local page
		page=$(fetch_page "$owner" "$repo" "$pr_number" "$reviews_cursor" "$threads_cursor" "$comments_cursor")

		local pr_data
		pr_data=$(echo "$page" | jq '.data.repository.pullRequest')

		# Check for null PR (not found)
		if [[ "$(echo "$pr_data" | jq -r 'type')" == "null" ]]; then
			echo "ERROR — PR #$pr_number not found in $owner/$repo" >&2
			exit 1
		fi

		# Merge reviews
		if [[ "$has_more_reviews" == "true" ]]; then
			all_reviews=$(echo "$all_reviews" "$pr_data" | jq -s '.[0] + (.[1].reviews.nodes // [])')
			has_more_reviews=$(echo "$pr_data" | jq -r '.reviews.pageInfo.hasNextPage')
			reviews_cursor=$(echo "$pr_data" | jq -r '.reviews.pageInfo.endCursor // empty')
		fi

		# Merge threads
		if [[ "$has_more_threads" == "true" ]]; then
			all_threads=$(echo "$all_threads" "$pr_data" | jq -s '.[0] + (.[1].reviewThreads.nodes // [])')
			has_more_threads=$(echo "$pr_data" | jq -r '.reviewThreads.pageInfo.hasNextPage')
			threads_cursor=$(echo "$pr_data" | jq -r '.reviewThreads.pageInfo.endCursor // empty')
		fi

		# Merge issue comments
		if [[ "$has_more_comments" == "true" ]]; then
			all_comments=$(echo "$all_comments" "$pr_data" | jq -s '.[0] + (.[1].comments.nodes // [])')
			has_more_comments=$(echo "$pr_data" | jq -r '.comments.pageInfo.hasNextPage')
			comments_cursor=$(echo "$pr_data" | jq -r '.comments.pageInfo.endCursor // empty')
		fi
	done

	jq -n --argjson reviews "$all_reviews" --argjson threads "$all_threads" --argjson comments "$all_comments" \
		'{reviews: $reviews, threads: $threads, comments: $comments}'
}

format_output() {
	local raw_json="$1"

	echo "$raw_json" | jq -r '
def is_security_sensitive:
  test("^\\.github/workflows/") or
  test("(^|/)deploy") or
  test("(^|/)secrets") or
  test("(^|/)\\.env") or
  test("Dockerfile") or
  test("(^|/)auth.*config");

def truncate(n):
  if length > n then .[:n] + "..." else . end;

def oneline:
  gsub("\n"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");

def summary_line:
  oneline | truncate(80);

# Process review threads
[.threads[] | {
  id: .id,
  type: "inline",
  is_resolved: .isResolved,
  author: (.comments.nodes[-1].author.login // "unknown"),
  path: (.comments.nodes[0].path // ""),
  line: (.comments.nodes[0].line // 0),
  body: ([.comments.nodes[].body] | join("\n---\n")),
  is_out_of_scope: ((.comments.nodes[0].path // "") | is_security_sensitive)
}] +
# Process top-level reviews with non-empty body
[.reviews[] |
  select((.state == "CHANGES_REQUESTED" or .state == "COMMENTED") and (.body // "" | length > 0)) |
  {
    id: .id,
    type: "top-level",
    is_resolved: false,
    author: (.author.login // "unknown"),
    path: "",
    line: 0,
    body: .body,
    is_out_of_scope: false
  }
] +
# Process PR issue comments with non-empty body
[.comments[] |
  select((.body // "" | length > 0)) |
  {
    id: .id,
    type: "top-level",
    is_resolved: false,
    author: (.author.login // "unknown"),
    path: "",
    line: 0,
    body: .body,
    is_out_of_scope: false
  }
] |

# Group into categories
group_by(
  if .is_resolved then "resolved"
  elif .is_out_of_scope then "out_of_scope"
  else "unresolved"
  end
) | map({
  key: (.[0] |
    if .is_resolved then "resolved"
    elif .is_out_of_scope then "out_of_scope"
    else "unresolved"
    end
  ),
  value: .
}) | from_entries |

# Defaults for missing groups
(.resolved // []) as $resolved |
(.unresolved // []) as $unresolved |
(.out_of_scope // []) as $out_of_scope |

# Format RESOLVED section
"RESOLVED:\($resolved | length)",
($resolved[] |
  "- @\(.author) (\(.type), \(.path):\(.line), thread:\(.id)) — \(.body | summary_line)"
),
"",

# Format UNRESOLVED section
"UNRESOLVED:\($unresolved | length)",
($unresolved | to_entries[] |
  "\(.key + 1). @\(.value.author) (\(.value.type), \(
    if .value.path != "" then "\(.value.path):\(.value.line), " else "" end
  )\(
    if .value.type == "inline" then "thread" else "review" end
  ):\(.value.id)) — \(.value.body | summary_line)",
  "   > \(.value.body | gsub("\n"; "\n   > "))",
  ""
),

# Format OUT_OF_SCOPE section
"OUT_OF_SCOPE:\($out_of_scope | length)",
($out_of_scope[] |
  "- @\(.author) (\(.type), \(.path):\(.line), thread:\(.id)) — \(.body | summary_line)"
)
'
}

main() {
	[[ $# -ne 3 ]] && usage
	check_deps

	local owner="$1"
	local repo="$2"
	local pr_number="$3"

	# Validate pr_number is numeric
	if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
		echo "ERROR — pr-number must be numeric, got '$pr_number'" >&2
		exit 1
	fi

	local raw_data
	raw_data=$(fetch_all "$owner" "$repo" "$pr_number")
	format_output "$raw_data"
}

main "$@"
