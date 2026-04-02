#!/bin/bash
# handlers/mentions.sh — Mention response handler for the unified worker.
# Scans GitHub issues and PRs for unhandled @mentions, then dispatches
# to branch-edit or read-only response mode.
#
# Uses the Python GitHub module for all API interactions.
#
# Handler interface:
#   handler_mentions_priority   — 10 (higher priority than issues)
#   handler_mentions_find_work  — returns first actionable mention as JSON
#   handler_mentions_execute    — builds context, invokes Claude, marks handled

PROMPT_DIR="$SCRIPT_DIR/prompts"
GITHUB_CLI="python3 -m dw_github.cli"

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
    claude $CLAUDE_MENTION_REPLY_FLAGS $CLAUDE_PLUGIN_FLAGS -p "$prompt" 2>&1 || {
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
    claude $CLAUDE_MENTION_REPLY_FLAGS $CLAUDE_PLUGIN_FLAGS -p "$prompt" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: Claude failed for $repo#$number"
        cd - > /dev/null
        rm -rf "$readonly_workdir"
        return 1
    }

    cd - > /dev/null
    rm -rf "$readonly_workdir"
    return 0
}

# ===========================================================================
# Handler interface
# ===========================================================================

handler_mentions_priority=10

handler_mentions_find_work() {
    local repo="$1"

    # Use Python module to find actionable mentions
    local result
    result=$($GITHUB_CLI find-mention --repo "$repo" 2>/dev/null) || return 1
    [[ -z "$result" ]] && return 0

    echo "$result"
    return 0
}

handler_mentions_execute() {
    local repo="$1"
    local task_json="$2"

    local m_id m_source m_number m_branch m_review_id
    m_id=$(echo "$task_json" | jq -r '.id')
    m_source=$(echo "$task_json" | jq -r '.source')
    m_number=$(echo "$task_json" | jq -r '.number')
    m_branch=$(echo "$task_json" | jq -r '.pr_branch')

    echo "[$(date -Iseconds)] $MENTION mention ($m_source) on $repo#$m_number"

    # Build context via Python module
    local full_context
    full_context=$($GITHUB_CLI mention-context --repo "$repo" --mention-json "$task_json" 2>/dev/null)

    if [[ "$m_branch" != "null" && -n "$m_branch" ]]; then
        respond_on_branch "$repo" "$m_number" "$full_context" "$m_branch" || true
    else
        respond_readonly "$repo" "$m_number" "$full_context" || true
    fi

    # Mark mention as handled via Python module
    $GITHUB_CLI mark-mention-handled --mention-id "$m_id" 2>/dev/null
}
