#!/bin/bash
# comment-monitor.sh — Responds to @dockworker mentions in GitHub issues and PRs.
# Runs every 5 minutes via cron. Silent when there are no mentions to handle.
# Processes ONE mention per cycle for quality responses.
#
# Scans for unhandled @dockworker mentions across:
#   - Issue comments (on monitored repos)
#   - PR conversation comments
#   - PR review comments (inline code comments on diffs)
#   - PR review summaries (approve/request changes with body text)
#
# Context is determined by where the mention is found:
#   - On a PR with a claude/* branch → checks out branch, can make edits + push
#   - On an issue or PR without a branch → read-only research from shared clone
#
# Uses the shared repo clone from repos/ so Claude has full file access.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

setup_logging "comment-monitor"
ensure_dirs
acquire_lock "comment-monitor" || exit 0
load_config

REPO_CACHE_DIR="$WORK_DIR/repos"
HANDLED_MENTIONS_FILE="$STATE_DIR/handled-mentions.json"
[[ -f "$HANDLED_MENTIONS_FILE" ]] || echo '{}' > "$HANDLED_MENTIONS_FILE"

# ---------------------------------------------------------------------------
# ensure_repo_clone — reuse from issue-worker's shared clone
# ---------------------------------------------------------------------------
ensure_repo_clone() {
    local repo="$1"
    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    repo_dir="$REPO_CACHE_DIR/$dir_name"

    if [[ -d "$repo_dir/.git" ]]; then
        return 0
    else
        mkdir -p "$REPO_CACHE_DIR"
        echo "[$(date -Iseconds)] Cloning $repo (first time from comment-monitor)"
        gh repo clone "$repo" "$repo_dir" 2>&1 || {
            echo "[$(date -Iseconds)] ERROR: Failed to clone $repo"
            return 1
        }
    fi
    return 0
}

# ---------------------------------------------------------------------------
# is_mention_handled — check if a comment ID has already been processed
# ---------------------------------------------------------------------------
is_mention_handled() {
    local comment_id="$1"
    local result
    result=$(jq -r --arg k "$comment_id" '.[$k] // "null"' "$HANDLED_MENTIONS_FILE" 2>/dev/null)
    [[ "$result" != "null" ]]
}

# ---------------------------------------------------------------------------
# mark_mention_handled — record that a mention has been processed
# ---------------------------------------------------------------------------
mark_mention_handled() {
    local comment_id="$1"
    local tmp="${HANDLED_MENTIONS_FILE}.tmp"
    jq --arg k "$comment_id" --arg t "$(date -Iseconds)" '.[$k] = $t' "$HANDLED_MENTIONS_FILE" > "$tmp" && mv "$tmp" "$HANDLED_MENTIONS_FILE"
}

# ---------------------------------------------------------------------------
# respond_on_branch — checkout PR branch, run Claude, let Claude commit/push/reply
# ---------------------------------------------------------------------------
respond_on_branch() {
    local repo="$1"
    local issue_number="$2"
    local pr_number="$3"
    local full_context="$4"
    local branch_name="$5"

    ensure_repo_clone "$repo" || return 1

    if ! acquire_repo_lock "$repo"; then
        echo "[$(date -Iseconds)] Repo $repo locked by issue-worker, will retry next cycle"
        return 1
    fi

    cd "$repo_dir"
    git fetch origin 2>/dev/null || true
    git checkout "$branch_name" 2>/dev/null || {
        echo "[$(date -Iseconds)] ERROR: Branch $branch_name not found"
        cd - > /dev/null
        release_repo_lock
        return 1
    }
    git pull --rebase origin "$branch_name" 2>/dev/null || true

    claude --model opus -p "You are an automated assistant responding to a mention in a GitHub pull request.
You are inside the repository's working directory on the PR branch.
You have full access to read files, explore the codebase, and make edits.

Repository: $repo
Issue #$issue_number / PR #$pr_number

Full context:
$full_context

Instructions:
1. Read the comment that mentioned you carefully.
2. Explore relevant files in the repository to give an informed response.
3. If the comment requests code changes or adjustments, go ahead and make them.
4. If the comment asks a question about the code, look at the actual files and give
   a specific, grounded answer.
5. If you made any file changes, stage, commit, and push them to the current branch.
   Use commit message: \"address feedback on issue #$issue_number\"
   Add Co-Authored-By: Claude <noreply@anthropic.com> to each commit.
6. When done, post a reply on PR #$pr_number (NOT issue #$issue_number) using:
   gh issue comment $pr_number -R $repo --body \"<your reply>\"
   End every reply with this signature on its own line: $BOT_SIGNATURE" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: Claude failed for $repo PR #$pr_number"
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    local _default_branch
    _default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    [[ -z "$_default_branch" ]] && _default_branch="main"
    git checkout "$_default_branch" 2>/dev/null

    cd - > /dev/null
    release_repo_lock
    return 0
}

# ---------------------------------------------------------------------------
# respond_readonly — run Claude in a read-only clone context
# Sets $reply
# ---------------------------------------------------------------------------
respond_readonly() {
    local repo="$1"
    local number="$2"
    local full_context="$3"

    ensure_repo_clone "$repo" || return 1

    cd "$repo_dir"
    claude --model opus -p "You are an automated assistant responding to a mention on GitHub.
You are inside the repository's working directory and can read any files for context.

Repository: $repo
Issue/PR #$number

Full context:
$full_context

Instructions:
1. Read the comment that mentioned you carefully.
2. Explore relevant files in the repository to give an informed response.
3. Reference specific files, functions, and code when answering.
4. Write a concise, grounded response based on what you find in the actual codebase.
5. When done, post your reply on the issue/PR using gh issue comment.
   End every reply with this signature on its own line: $BOT_SIGNATURE" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: Claude failed for $repo#$number"
        cd - > /dev/null
        return 1
    }
    cd - > /dev/null
    return 0
}

# ---------------------------------------------------------------------------
# find_pr_branch — check if a PR has a claude/* branch we can work on
# Sets $found_branch if found, empty string otherwise
# ---------------------------------------------------------------------------
find_pr_branch() {
    local repo="$1"
    local pr_number="$2"
    found_branch=$(gh pr view "$pr_number" -R "$repo" --json headRefName --jq '.headRefName' 2>/dev/null)
    if [[ "$found_branch" == claude/* ]]; then
        return 0
    fi
    found_branch=""
    return 1
}

# ===========================================================================
# Scan all comment sources for unhandled @dockworker mentions
# ===========================================================================

for repo in "${REPOS[@]}"; do
    set_app_token_for_repo "$repo"

    # -------------------------------------------------------------------
    # 1. PR review comments (inline code comments on diffs)
    # -------------------------------------------------------------------
    prs_json=$(gh pr list -R "$repo" --state open --json number,headRefName \
        --jq '[.[] | select(.headRefName | startswith("claude/"))]' 2>/dev/null) || prs_json="[]"

    pr_count=$(echo "$prs_json" | jq length 2>/dev/null)
    for pi in $(seq 0 $((${pr_count:-0} - 1))); do
        pr_number=$(echo "$prs_json" | jq -r ".[$pi].number")
        branch_name=$(echo "$prs_json" | jq -r ".[$pi].headRefName")
        issue_number=$(echo "$branch_name" | sed 's/claude\/issue-//')

        # PR review comments (inline)
        review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, path, line: .line, created_at}) | sort_by(.created_at)' 2>/dev/null) || continue

        for ri in $(seq 0 $(($(echo "$review_comments" | jq length) - 1))); do
            rc_id=$(echo "$review_comments" | jq -r ".[$ri].id")
            rc_body=$(echo "$review_comments" | jq -r ".[$ri].body")
            rc_user=$(echo "$review_comments" | jq -r ".[$ri].user")

            is_mention_handled "$rc_id" && continue
            ! has_mention "$rc_body" && continue
            is_bot_comment "$rc_body" && { mark_mention_handled "$rc_id"; continue; }
            ! is_authorized_user "$rc_user" && { mark_mention_handled "$rc_id"; continue; }

            echo "[$(date -Iseconds)] $MENTION mention in PR review comment on $repo PR #$pr_number"

            full_context=$(gh issue view "$issue_number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || full_context="{}"
            review_ctx=$(echo "$review_comments" | jq '[.[] | {author: .user, path, line, body}]')
            full_context=$(echo "$full_context" | jq --argjson rc "$review_ctx" '. + {review_comments: $rc}')

            respond_on_branch "$repo" "$issue_number" "$pr_number" "$full_context" "$branch_name" || true
            mark_mention_handled "$rc_id"
            exit 0
        done

        # PR review summaries (approve/request changes)
        reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, state, submitted_at}) | sort_by(.submitted_at)' 2>/dev/null) || continue

        for ri in $(seq 0 $(($(echo "$reviews" | jq length) - 1))); do
            rv_id=$(echo "$reviews" | jq -r ".[$ri].id")
            rv_body=$(echo "$reviews" | jq -r ".[$ri].body")
            rv_state=$(echo "$reviews" | jq -r ".[$ri].state")
            rv_user=$(echo "$reviews" | jq -r ".[$ri].user")

            is_mention_handled "$rv_id" && continue
            [[ -z "$rv_body" || "$rv_body" == "null" ]] && continue
            ! has_mention "$rv_body" && continue
            is_bot_comment "$rv_body" && { mark_mention_handled "$rv_id"; continue; }
            ! is_authorized_user "$rv_user" && { mark_mention_handled "$rv_id"; continue; }

            echo "[$(date -Iseconds)] $MENTION mention in PR review ($rv_state) on $repo PR #$pr_number"

            full_context=$(gh issue view "$issue_number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || full_context="{}"
            full_context=$(echo "$full_context" | jq --arg rs "$rv_state" --arg rb "$rv_body" \
                '. + {latest_review: {state: $rs, body: $rb}}')

            respond_on_branch "$repo" "$issue_number" "$pr_number" "$full_context" "$branch_name" || true
            mark_mention_handled "$rv_id"
            exit 0
        done

        # PR conversation comments
        pr_comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, created_at})' 2>/dev/null) || continue

        for ci in $(seq 0 $(($(echo "$pr_comments" | jq length) - 1))); do
            pc_id=$(echo "$pr_comments" | jq -r ".[$ci].id")
            pc_body=$(echo "$pr_comments" | jq -r ".[$ci].body")
            pc_user=$(echo "$pr_comments" | jq -r ".[$ci].user")

            is_mention_handled "$pc_id" && continue
            ! has_mention "$pc_body" && continue
            is_bot_comment "$pc_body" && { mark_mention_handled "$pc_id"; continue; }
            ! is_authorized_user "$pc_user" && { mark_mention_handled "$pc_id"; continue; }

            echo "[$(date -Iseconds)] $MENTION mention in PR conversation on $repo PR #$pr_number"

            full_context=$(gh issue view "$issue_number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || full_context="{}"
            pr_conv=$(echo "$pr_comments" | jq '[.[] | {author: .user, body}]')
            full_context=$(echo "$full_context" | jq --argjson pc "$pr_conv" '. + {pr_comments: $pc}')

            respond_on_branch "$repo" "$issue_number" "$pr_number" "$full_context" "$branch_name" || true
            mark_mention_handled "$pc_id"
            exit 0
        done
    done

    # -------------------------------------------------------------------
    # 2. Issue comments — scan all open issues in monitored repos
    # -------------------------------------------------------------------
    issues_json=$(gh issue list -R "$repo" --state open --json number,title --limit 100 2>/dev/null) || continue

    issue_count=$(echo "$issues_json" | jq length)
    for ii in $(seq 0 $((${issue_count:-0} - 1))); do
        issue_number=$(echo "$issues_json" | jq -r ".[$ii].number")
        issue_title=$(echo "$issues_json" | jq -r ".[$ii].title")

        comments_json=$(gh api "repos/${repo}/issues/${issue_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, created_at})' 2>/dev/null) || continue

        for ci in $(seq 0 $(($(echo "$comments_json" | jq length) - 1))); do
            c_id=$(echo "$comments_json" | jq -r ".[$ci].id")
            c_body=$(echo "$comments_json" | jq -r ".[$ci].body")
            c_user=$(echo "$comments_json" | jq -r ".[$ci].user")

            is_mention_handled "$c_id" && continue
            ! has_mention "$c_body" && continue
            is_bot_comment "$c_body" && { mark_mention_handled "$c_id"; continue; }
            ! is_authorized_user "$c_user" && { mark_mention_handled "$c_id"; continue; }

            echo "[$(date -Iseconds)] $MENTION mention on $repo#$issue_number: $issue_title"

            full_context=$(gh issue view "$issue_number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || continue

            # Check if there's an associated PR we can work on
            pr_status=$(read_state_field "$PROCESSED_ISSUES_FILE" "${repo}#${issue_number}" "status")

            if [[ "$pr_status" == "pr-opened" ]]; then
                branch_name="claude/issue-${issue_number}"
                pr_number=$(read_state_field "$PROCESSED_ISSUES_FILE" "${repo}#${issue_number}" "pr_url" | grep -oP '\d+$')
                if respond_on_branch "$repo" "$issue_number" "${pr_number:-$issue_number}" "$full_context" "$branch_name"; then
                    # Cross-reference: let the issue commenter know the response is on the PR
                    gh issue comment "$issue_number" -R "$repo" \
                        --body "Responded on the linked PR: #${pr_number:-$issue_number}

$BOT_SIGNATURE" 2>/dev/null || true
                else
                    respond_readonly "$repo" "$issue_number" "$full_context" || true
                fi
            else
                respond_readonly "$repo" "$issue_number" "$full_context" || true
            fi

            mark_mention_handled "$c_id"
            exit 0
        done

        # Also check the issue body itself for a mention (first-contact scenario)
        issue_data=$(gh issue view "$issue_number" -R "$repo" --json body,author --jq '{body, author: .author.login}' 2>/dev/null) || continue
        issue_body=$(echo "$issue_data" | jq -r '.body')
        issue_author=$(echo "$issue_data" | jq -r '.author')
        body_key="issue-body-${repo}#${issue_number}"

        if has_mention "$issue_body" && ! is_mention_handled "$body_key" && is_authorized_user "$issue_author"; then
            echo "[$(date -Iseconds)] $MENTION mention in issue body on $repo#$issue_number: $issue_title"

            full_context=$(gh issue view "$issue_number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || continue

            respond_readonly "$repo" "$issue_number" "$full_context" || true

            mark_mention_handled "$body_key"
            exit 0
        fi
    done
done
