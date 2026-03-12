#!/usr/bin/env bash
# Fetch bot review comments from a GitHub PR
# Usage: fetch_reviews.sh [--pr <number>] [--repo <owner/repo>]
# If --pr is omitted, detects from current branch.
# Outputs JSON array of review comments from known bots.

set -euo pipefail

BOT_LOGINS=(
  "cursor-bugbot"
  "cursor-bugbot[bot]"
  "github-actions[bot]"
  "copilot"
  "copilot[bot]"
  "github-copilot[bot]"
  "copilot-pull-request-reviewer[bot]"
  "gemini-code-assist[bot]"
  "sentry[bot]"
  "sentry-io[bot]"
  "linear[bot]"
)

PR_NUMBER=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Auto-detect repo from git remote
if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
  if [[ -z "$REPO" ]]; then
    echo "ERROR: Could not detect repository. Use --repo owner/repo" >&2
    exit 1
  fi
fi

# Auto-detect PR from current branch
if [[ -z "$PR_NUMBER" ]]; then
  BRANCH=$(git branch --show-current 2>/dev/null || true)
  if [[ -z "$BRANCH" ]]; then
    echo "ERROR: Not on a branch and no --pr specified" >&2
    exit 1
  fi
  PR_NUMBER=$(gh pr view "$BRANCH" --json number -q '.number' 2>/dev/null || true)
  if [[ -z "$PR_NUMBER" ]]; then
    echo "ERROR: No PR found for branch '$BRANCH'. Use --pr <number>" >&2
    exit 1
  fi
fi

echo "PR_NUMBER=$PR_NUMBER" >&2
echo "REPO=$REPO" >&2

# Build jq filter for bot logins
BOT_FILTER=$(printf '"%s",' "${BOT_LOGINS[@]}")
BOT_FILTER="[${BOT_FILTER%,}]"

# Fetch review comments (inline code comments)
REVIEW_COMMENTS=$(gh api \
  --paginate \
  "repos/${REPO}/pulls/${PR_NUMBER}/comments" \
  --jq "[.[] | select(.user.login as \$login | ${BOT_FILTER} | index(\$login)) | {
    id: .id,
    bot: .user.login,
    path: .path,
    line: (.original_line // .line // .position),
    diff_hunk: .diff_hunk,
    body: .body,
    url: .html_url,
    in_reply_to_id: .in_reply_to_id,
    created_at: .created_at
  }]" 2>/dev/null || echo "[]")

# Fetch PR-level review comments (review body comments)
PR_REVIEWS=$(gh api \
  --paginate \
  "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --jq "[.[] | select(.user.login as \$login | ${BOT_FILTER} | index(\$login)) | select(.body != null and .body != \"\") | {
    id: .id,
    bot: .user.login,
    path: \"(PR-level review)\",
    line: null,
    diff_hunk: null,
    body: .body,
    url: .html_url,
    in_reply_to_id: null,
    created_at: .submitted_at
  }]" 2>/dev/null || echo "[]")

# Fetch issue comments (some bots post as issue comments)
ISSUE_COMMENTS=$(gh api \
  --paginate \
  "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq "[.[] | select(.user.login as \$login | ${BOT_FILTER} | index(\$login)) | {
    id: .id,
    bot: .user.login,
    path: \"(PR-level comment)\",
    line: null,
    diff_hunk: null,
    body: .body,
    url: .html_url,
    in_reply_to_id: null,
    created_at: .created_at
  }]" 2>/dev/null || echo "[]")

# Merge all comments into one JSON array
echo "${REVIEW_COMMENTS}" "${PR_REVIEWS}" "${ISSUE_COMMENTS}" | jq -s 'add | sort_by(.created_at)'
