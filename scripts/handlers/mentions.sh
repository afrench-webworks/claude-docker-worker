#!/bin/bash
# handlers/mentions.sh — Mention response handler for the unified worker.
# Scans GitHub issues and PRs for unhandled @mentions, then dispatches
# to branch-edit or read-only response mode.
#
# Handler interface:
#   handler_mentions_priority   — 10 (higher priority than issues)
#   handler_mentions_find_work  — returns first actionable mention as JSON
#   handler_mentions_execute    — builds context, invokes Claude, marks handled

PROMPT_DIR="$SCRIPT_DIR/prompts"
HANDLED_MENTIONS_FILE="$STATE_DIR/handled-mentions.json"
[[ -f "$HANDLED_MENTIONS_FILE" ]] || echo '{}' > "$HANDLED_MENTIONS_FILE"

# ---------------------------------------------------------------------------
# State tracking
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
        echo "[$(date -Iseconds)] Repo $repo locked, will retry next cycle"
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

    # shellcheck disable=SC2086
    claude --model opus $CLAUDE_COMMON_FLAGS $CLAUDE_PLUGIN_FLAGS -p "$prompt" 2>&1 || {
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

    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    local readonly_workdir="$WORK_DIR/readonly-${dir_name}-$$"
    cp -a "$repo_dir"/. "$readonly_workdir"/
    rm -rf "$readonly_workdir/.git"

    cd "$readonly_workdir"

    local prompt
    prompt=$(render_prompt "$PROMPT_DIR/respond-readonly.md" "$repo" "$number" "$full_context")

    # shellcheck disable=SC2086
    claude --model opus $CLAUDE_COMMON_FLAGS $CLAUDE_PLUGIN_FLAGS -p "$prompt" 2>&1 || {
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
# collect_mentions — gather all unhandled mentions from a repo
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

            local review_comments
            review_comments=$(gh api "repos/${repo}/pulls/${number}/comments" \
                --jq 'map({author: .user.login, path, line: .line, body})' 2>/dev/null) || review_comments="[]"
            context=$(echo "$context" | jq --argjson rc "$review_comments" '. + {review_comments: $rc}')

            local latest_review
            latest_review=$(gh api "repos/${repo}/pulls/${number}/reviews" \
                --jq '[.[] | select(.body != null and .body != "")] | sort_by(.submitted_at) | last // empty' 2>/dev/null) || latest_review=""
            if [[ -n "$latest_review" && "$latest_review" != "null" ]]; then
                context=$(echo "$context" | jq --argjson lr "$latest_review" \
                    '. + {latest_review: {state: $lr.state, body: $lr.body}}')

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
# Handler interface
# ===========================================================================

handler_mentions_priority=10

handler_mentions_find_work() {
    local repo="$1"
    local mentions
    mentions=$(collect_mentions "$repo")

    local count
    count=$(echo "$mentions" | jq length 2>/dev/null) || count=0

    for mi in $(seq 0 $((count - 1))); do
        local m_id m_body m_user
        m_id=$(echo "$mentions" | jq -r ".[$mi].id")
        m_body=$(echo "$mentions" | jq -r ".[$mi].body")
        m_user=$(echo "$mentions" | jq -r ".[$mi].user")

        # Standard filters
        is_mention_handled "$m_id" && continue
        ! has_mention "$m_body" && continue
        is_bot_comment "$m_body" && { mark_mention_handled "$m_id"; continue; }
        ! is_authorized_user "$m_user" && { mark_mention_handled "$m_id"; continue; }

        # Found actionable mention
        echo "$mentions" | jq -c ".[$mi]"
        return 0
    done
}

handler_mentions_execute() {
    local repo="$1"
    local task_json="$2"

    local m_id m_source m_number m_branch m_review_id
    m_id=$(echo "$task_json" | jq -r '.id')
    m_source=$(echo "$task_json" | jq -r '.source')
    m_number=$(echo "$task_json" | jq -r '.number')
    m_branch=$(echo "$task_json" | jq -r '.pr_branch')
    m_review_id=$(echo "$task_json" | jq -r '.review_id // empty')

    echo "[$(date -Iseconds)] $MENTION mention ($m_source) on $repo#$m_number"

    local full_context
    full_context=$(build_context "$repo" "$m_number" "$m_source" "$m_review_id")

    if [[ "$m_branch" != "null" && -n "$m_branch" ]]; then
        respond_on_branch "$repo" "$m_number" "$full_context" "$m_branch" || true
    else
        respond_readonly "$repo" "$m_number" "$full_context" || true
    fi

    mark_mention_handled "$m_id"
}
