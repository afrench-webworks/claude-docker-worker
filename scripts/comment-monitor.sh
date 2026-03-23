#!/bin/bash
# comment-monitor.sh — Responds to mentions in GitHub issues and PRs.
# Runs every 5 minutes via cron. Silent when there are no mentions to handle.
# Processes ONE mention per cycle for quality responses.
#
# Collects all unhandled mentions across every comment source (issue comments,
# issue bodies, PR conversations, PR review comments, PR review summaries),
# filters them, then dispatches to one of two response modes:
#
#   - On a PR with a branch → checks out branch, can make edits + push
#   - On an issue (no branch) → read-only copy, analysis only

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_DIR="$SCRIPT_DIR/prompts"
source "$SCRIPT_DIR/common.sh"

setup_logging "comment-monitor"
ensure_dirs
acquire_lock "comment-monitor" || exit 0
load_config

REPO_CACHE_DIR="$WORK_DIR/repos"
HANDLED_MENTIONS_FILE="$STATE_DIR/handled-mentions.json"
[[ -f "$HANDLED_MENTIONS_FILE" ]] || echo '{}' > "$HANDLED_MENTIONS_FILE"

# Clean up stale readonly temp dirs (older than 1 hour)
find "$WORK_DIR" -maxdepth 1 -name "readonly-*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null

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
# is_mention_handled / mark_mention_handled — state tracking
# ---------------------------------------------------------------------------
is_mention_handled() {
    local comment_id="$1"
    local result
    result=$(jq -r --arg k "$comment_id" '.[$k] // "null"' "$HANDLED_MENTIONS_FILE" 2>/dev/null)
    [[ "$result" != "null" ]]
}

mark_mention_handled() {
    local comment_id="$1"
    local tmp="${HANDLED_MENTIONS_FILE}.tmp"
    jq --arg k "$comment_id" --arg t "$(date -Iseconds)" '.[$k] = $t' "$HANDLED_MENTIONS_FILE" > "$tmp" && mv "$tmp" "$HANDLED_MENTIONS_FILE"
}

# ---------------------------------------------------------------------------
# render_prompt — read a template file and substitute {{variables}}
# ---------------------------------------------------------------------------
render_prompt() {
    local template_file="$1"
    local repo="$2"
    local number="$3"
    local context="$4"
    local branch="${5:-}"

    local prompt
    prompt=$(<"$template_file")

    # Use parameter expansion for simple substitutions, heredoc for context
    prompt="${prompt//\{\{repo\}\}/$repo}"
    prompt="${prompt//\{\{number\}\}/$number}"
    prompt="${prompt//\{\{branch\}\}/$branch}"
    prompt="${prompt//\{\{bot_signature\}\}/$BOT_SIGNATURE}"
    prompt="${prompt//\{\{context\}\}/$context}"

    printf '%s' "$prompt"
}

# ---------------------------------------------------------------------------
# respond_on_branch — checkout PR branch, run Claude, let it edit/commit/push
# ---------------------------------------------------------------------------
respond_on_branch() {
    local repo="$1"
    local pr_number="$2"
    local full_context="$3"
    local branch_name="$4"

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

    local prompt
    prompt=$(render_prompt "$PROMPT_DIR/respond-on-branch.md" "$repo" "$pr_number" "$full_context" "$branch_name")

    claude --model opus -p "$prompt" 2>&1 || {
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
# respond_readonly — run Claude in a gitless copy (structurally read-only)
# ---------------------------------------------------------------------------
respond_readonly() {
    local repo="$1"
    local number="$2"
    local full_context="$3"

    ensure_repo_clone "$repo" || return 1

    # Create a gitless copy so Claude structurally cannot commit anywhere
    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    local readonly_workdir="$WORK_DIR/readonly-${dir_name}-$$"
    cp -a "$repo_dir"/. "$readonly_workdir"/
    rm -rf "$readonly_workdir/.git"

    cd "$readonly_workdir"

    local prompt
    prompt=$(render_prompt "$PROMPT_DIR/respond-readonly.md" "$repo" "$number" "$full_context")

    claude --model opus -p "$prompt" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: Claude failed for $repo#$number"
        cd - > /dev/null
        rm -rf "$readonly_workdir"
        return 1
    }

    cd - > /dev/null
    rm -rf "$readonly_workdir"
    return 0
}

# ---------------------------------------------------------------------------
# collect_mentions — gather all unhandled mentions from a repo into a JSON array
# ---------------------------------------------------------------------------
collect_mentions() {
    local repo="$1"
    local mentions="[]"

    # --- PRs: conversation comments, review comments, review summaries ---
    local prs_json
    prs_json=$(gh pr list -R "$repo" --state open --json number,headRefName 2>/dev/null) || prs_json="[]"

    local pr_count
    pr_count=$(echo "$prs_json" | jq length 2>/dev/null) || pr_count=0

    for pi in $(seq 0 $((pr_count - 1))); do
        local pr_number branch_name
        pr_number=$(echo "$prs_json" | jq -r ".[$pi].number")
        branch_name=$(echo "$prs_json" | jq -r ".[$pi].headRefName")

        # PR conversation comments
        local pr_comments
        pr_comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login})' 2>/dev/null) || pr_comments="[]"

        mentions=$(echo "$mentions" | jq --argjson comments "$pr_comments" \
            --arg src "pr-conversation" --arg num "$pr_number" --arg branch "$branch_name" \
            '. + [$comments[] | . + {source: $src, number: ($num | tonumber), pr_branch: $branch}]')

        # PR review comments (inline code comments)
        local review_comments
        review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, path, line: .line})' 2>/dev/null) || review_comments="[]"

        mentions=$(echo "$mentions" | jq --argjson comments "$review_comments" \
            --arg src "pr-review-comment" --arg num "$pr_number" --arg branch "$branch_name" \
            '. + [$comments[] | . + {source: $src, number: ($num | tonumber), pr_branch: $branch}]')

        # PR review summaries
        local reviews
        reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
            --jq 'map({id: (.id | tostring), body, user: .user.login, state, review_id: (.id | tostring)}) | map(select(.body != null and .body != ""))' 2>/dev/null) || reviews="[]"

        mentions=$(echo "$mentions" | jq --argjson comments "$reviews" \
            --arg src "pr-review" --arg num "$pr_number" --arg branch "$branch_name" \
            '. + [$comments[] | . + {source: $src, number: ($num | tonumber), pr_branch: $branch}]')
    done

    # --- Issues: comments and bodies ---
    local issues_json
    issues_json=$(gh issue list -R "$repo" --state open --json number,title --limit 100 2>/dev/null) || issues_json="[]"

    local issue_count
    issue_count=$(echo "$issues_json" | jq length 2>/dev/null) || issue_count=0

    for ii in $(seq 0 $((issue_count - 1))); do
        local issue_number issue_title
        issue_number=$(echo "$issues_json" | jq -r ".[$ii].number")
        issue_title=$(echo "$issues_json" | jq -r ".[$ii].title")

        # Issue comments
        local issue_comments
        issue_comments=$(gh api "repos/${repo}/issues/${issue_number}/comments" \
            --jq 'map({id: (.id | tostring), body, user: .user.login})' 2>/dev/null) || issue_comments="[]"

        mentions=$(echo "$mentions" | jq --argjson comments "$issue_comments" \
            --arg src "issue-comment" --arg num "$issue_number" \
            '. + [$comments[] | . + {source: $src, number: ($num | tonumber), pr_branch: null}]')

        # Issue body
        local issue_data
        issue_data=$(gh issue view "$issue_number" -R "$repo" --json body,author \
            --jq '{body, author: .author.login}' 2>/dev/null) || continue

        local issue_body issue_author
        issue_body=$(echo "$issue_data" | jq -r '.body')
        issue_author=$(echo "$issue_data" | jq -r '.author')

        if [[ -n "$issue_body" && "$issue_body" != "null" ]]; then
            local body_id="issue-body-${repo}#${issue_number}"
            mentions=$(echo "$mentions" | jq --arg id "$body_id" --arg body "$issue_body" \
                --arg user "$issue_author" --arg num "$issue_number" \
                '. + [{id: $id, body: $body, user: $user, source: "issue-body", number: ($num | tonumber), pr_branch: null}]')
        fi
    done

    echo "$mentions"
}

# ---------------------------------------------------------------------------
# build_context — assemble full context JSON for a mention
# ---------------------------------------------------------------------------
build_context() {
    local repo="$1"
    local number="$2"
    local source="$3"
    local review_id="${4:-}"

    local context="{}"

    case "$source" in
        pr-conversation|pr-review-comment|pr-review)
            context=$(gh pr view "$number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || context="{}"

            # Include all inline review comments
            local review_comments
            review_comments=$(gh api "repos/${repo}/pulls/${number}/comments" \
                --jq 'map({author: .user.login, path, line: .line, body})' 2>/dev/null) || review_comments="[]"
            context=$(echo "$context" | jq --argjson rc "$review_comments" '. + {review_comments: $rc}')

            # Include latest review state
            local latest_review
            latest_review=$(gh api "repos/${repo}/pulls/${number}/reviews" \
                --jq '[.[] | select(.body != null and .body != "")] | sort_by(.submitted_at) | last // empty' 2>/dev/null) || latest_review=""
            if [[ -n "$latest_review" && "$latest_review" != "null" ]]; then
                context=$(echo "$context" | jq --argjson lr "$latest_review" \
                    '. + {latest_review: {state: $lr.state, body: $lr.body}}')

                # If this is a review mention, fetch that review's inline comments
                if [[ "$source" == "pr-review" && -n "$review_id" ]]; then
                    local review_inline
                    review_inline=$(gh api "repos/${repo}/pulls/${number}/reviews/${review_id}/comments" \
                        --jq 'map({path, line: .line, body, author: .user.login})' 2>/dev/null) || review_inline="[]"
                    context=$(echo "$context" | jq --argjson ric "$review_inline" \
                        '.latest_review.inline_comments = $ric')
                fi
            fi
            ;;
        issue-comment|issue-body)
            context=$(gh issue view "$number" -R "$repo" --json title,body,comments \
                --jq '{title, body, comments: [.comments[] | {author: .author.login, body}]}' 2>/dev/null) || context="{}"

            # Check if there's an associated PR we can reference
            local pr_status
            pr_status=$(read_state_field "$PROCESSED_ISSUES_FILE" "${repo}#${number}" "status")
            if [[ "$pr_status" == "pr-opened" ]]; then
                local pr_url
                pr_url=$(read_state_field "$PROCESSED_ISSUES_FILE" "${repo}#${number}" "pr_url")
                context=$(echo "$context" | jq --arg pr "$pr_url" '. + {linked_pr: $pr}')
            fi
            ;;
    esac

    echo "$context"
}

# ===========================================================================
# Main loop: collect mentions, filter, dispatch
# ===========================================================================

for repo in "${REPOS[@]}"; do
    set_app_token_for_repo "$repo"

    mentions=$(collect_mentions "$repo")
    mention_count=$(echo "$mentions" | jq length 2>/dev/null) || mention_count=0

    for mi in $(seq 0 $((mention_count - 1))); do
        m_id=$(echo "$mentions" | jq -r ".[$mi].id")
        m_body=$(echo "$mentions" | jq -r ".[$mi].body")
        m_user=$(echo "$mentions" | jq -r ".[$mi].user")
        m_source=$(echo "$mentions" | jq -r ".[$mi].source")
        m_number=$(echo "$mentions" | jq -r ".[$mi].number")
        m_branch=$(echo "$mentions" | jq -r ".[$mi].pr_branch")
        m_review_id=$(echo "$mentions" | jq -r ".[$mi].review_id // empty")

        # Standard filters
        is_mention_handled "$m_id" && continue
        ! has_mention "$m_body" && continue
        is_bot_comment "$m_body" && { mark_mention_handled "$m_id"; continue; }
        ! is_authorized_user "$m_user" && { mark_mention_handled "$m_id"; continue; }

        echo "[$(date -Iseconds)] $MENTION mention ($m_source) on $repo#$m_number"

        # Build context
        full_context=$(build_context "$repo" "$m_number" "$m_source" "$m_review_id")

        # Dispatch: branch available → edit mode, otherwise → readonly
        if [[ "$m_branch" != "null" && -n "$m_branch" ]]; then
            respond_on_branch "$repo" "$m_number" "$full_context" "$m_branch" || true
        else
            respond_readonly "$repo" "$m_number" "$full_context" || true
        fi

        mark_mention_handled "$m_id"
        exit 0
    done
done
