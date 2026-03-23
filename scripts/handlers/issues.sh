#!/bin/bash
# handlers/issues.sh — Issue implementation handler for the unified worker.
# Picks up labeled GitHub issues, implements changes via Claude Code,
# and opens a PR. Respects a configurable work window.
#
# Handler interface:
#   handler_issues_priority      — 20 (lower priority than mentions)
#   handler_issues_find_work     — returns first eligible issue as JSON
#   handler_issues_execute       — implements changes, creates PR, updates state
#   handler_issues_is_in_window  — checks work window (default midnight–8 AM)

# ===========================================================================
# Handler interface
# ===========================================================================

handler_issues_priority=20

handler_issues_is_in_window() {
    # No window configured — always run
    [[ -z "$ISSUE_WORK_WINDOW_START" || -z "$ISSUE_WORK_WINDOW_END" ]] && return 0

    local current_hour
    current_hour=$(date +%-H)

    if [[ "$ISSUE_WORK_WINDOW_START" -le "$ISSUE_WORK_WINDOW_END" ]]; then
        [[ "$current_hour" -ge "$ISSUE_WORK_WINDOW_START" && "$current_hour" -lt "$ISSUE_WORK_WINDOW_END" ]]
    else
        # Wraps midnight (e.g., 22-6)
        [[ "$current_hour" -ge "$ISSUE_WORK_WINDOW_START" || "$current_hour" -lt "$ISSUE_WORK_WINDOW_END" ]]
    fi
}

handler_issues_find_work() {
    local repo="$1"

    local issues_json
    issues_json=$(gh issue list -R "$repo" --label "$LABEL" --state open \
        --json number,title,body --jq 'sort_by(.number)' 2>&1) || return 1

    local count
    count=$(echo "$issues_json" | jq length 2>/dev/null) || return 1
    [[ "$count" -eq 0 ]] && return 0

    for i in $(seq 0 $((count - 1))); do
        local number title body state_key status
        number=$(echo "$issues_json" | jq -r ".[$i].number")
        title=$(echo "$issues_json" | jq -r ".[$i].title")
        body=$(echo "$issues_json" | jq -r ".[$i].body")
        state_key="${repo}#${number}"

        status=$(read_state_field "$PROCESSED_ISSUES_FILE" "$state_key" "status")
        [[ "$status" == "pr-opened" || "$status" == "in-progress" || "$status" == "failed" ]] && continue

        # Found eligible issue
        jq -n -c --arg n "$number" --arg t "$title" --arg b "$body" \
            '{type: "issue", issue_number: $n, issue_title: $t, issue_body: $b}'
        return 0
    done
}

handler_issues_execute() {
    local repo="$1"
    local task_json="$2"

    local issue_number issue_title issue_body state_key
    issue_number=$(echo "$task_json" | jq -r '.issue_number')
    issue_title=$(echo "$task_json" | jq -r '.issue_title')
    issue_body=$(echo "$task_json" | jq -r '.issue_body')
    state_key="${repo}#${issue_number}"

    echo "[$(date -Iseconds)] Processing $repo#$issue_number: $issue_title"

    # Mark as in-progress
    write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
        "{\"status\":\"in-progress\",\"started_at\":\"$(date -Iseconds)\"}"

    # Acquire repo-level lock for git safety
    acquire_repo_lock "$repo" || {
        echo "[$(date -Iseconds)] Repo $repo is locked by another process, skipping"
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"pending\",\"reason\":\"repo-locked\",\"processed_at\":\"$(date -Iseconds)\"}"
        return 1
    }

    # Ensure we have an up-to-date clone
    ensure_repo_clone "$repo" true || {
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"clone-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        release_repo_lock
        return 1
    }

    cd "$repo_dir"

    # Determine default branch
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    [[ -z "$default_branch" ]] && default_branch="main"

    # Create a fresh working branch from the default branch
    local branch_name="claude/issue-${issue_number}"

    git checkout "$default_branch" 2>/dev/null
    git reset --hard "origin/$default_branch" 2>/dev/null
    git clean -fd 2>/dev/null
    git branch -D "$branch_name" 2>/dev/null || true
    git checkout -b "$branch_name"

    # Fetch full issue context including comments
    local full_context
    full_context=$(gh issue view "$issue_number" -R "$repo" \
        --json title,body,comments,labels \
        --jq '{title, body, labels: [.labels[].name], comments: [.comments[] | {author: .author.login, body}]}' 2>&1) || {
        echo "[$(date -Iseconds)] WARN: Could not fetch full issue context, using basic info"
        full_context="{\"title\": \"$issue_title\", \"body\": \"$issue_body\"}"
    }

    echo "[$(date -Iseconds)] Invoking Claude Code (Opus 4.6)"

    # Invoke Claude Code to implement the changes
    local claude_output
    # shellcheck disable=SC2086
    claude_output=$(claude --model opus $CLAUDE_COMMON_FLAGS $CLAUDE_PLUGIN_FLAGS -p "You are an automated developer working inside a cloned repository.
Your job is to implement changes for a GitHub issue. You have full access to the
codebase and all standard tools (read, write, edit, grep, glob, bash).

Repository: $repo
Issue #$issue_number

Full issue context:
$full_context

Instructions:
1. Explore the repository thoroughly — read relevant source files, understand the
   architecture, and identify the specific files that need to change.
2. Implement the requested changes. Edit files directly.
3. Make clean, minimal changes that address the issue.
4. Do NOT run any git commands — the automation handles branching, commits, and PRs.
5. If you cannot fully implement the change, make as much progress as possible and
   clearly explain what's left in your output.
6. If the issue is too vague or you need clarification, explain exactly what
   information is missing and what specific questions need to be answered.
7. At the end, write a meaningful description of what you did, what files you
   changed, and any remaining concerns or open questions. This will be used as
   the pull request description, so format it however you think is most useful." 2>&1) || {
        echo "[$(date -Iseconds)] ERROR: Claude Code invocation failed for $repo#$issue_number"
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"claude-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        # Redact any tokens that may appear in Claude's output
        local safe_output
        safe_output=$(echo "$claude_output" | sed -E 's/(ghp_|gho_|github_pat_|ghs_)[A-Za-z0-9_]+/[REDACTED]/g')
        gh issue comment "$issue_number" -R "$repo" --body "I attempted to work on this issue but encountered an error during implementation. Here's what happened:

$safe_output

${BOT_SIGNATURE}" 2>/dev/null
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    # Check if Claude actually made any changes
    if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        echo "[$(date -Iseconds)] No file changes produced for $repo#$issue_number"
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"needs-clarification\",\"processed_at\":\"$(date -Iseconds)\"}"

        gh issue comment "$issue_number" -R "$repo" --body "I reviewed this issue and explored the codebase but wasn't able to produce code changes. Here's my analysis:

$claude_output

If you can provide more specific guidance on the approach or which files to modify, I can try again on the next work cycle.

${BOT_SIGNATURE}" 2>/dev/null

        git checkout "$default_branch" 2>/dev/null
        git branch -D "$branch_name" 2>/dev/null || true
        cd - > /dev/null
        release_repo_lock
        return 0
    fi

    # Stage, commit, and push
    echo "[$(date -Iseconds)] Committing and pushing changes"
    git add -A
    if ! git diff --cached --quiet; then
        git commit -m "$(cat <<EOF
fix: address issue #$issue_number — $issue_title

Implemented changes as described in #$issue_number.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
    fi

    git push -u origin "$branch_name" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: Failed to push branch $branch_name"
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"push-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    # Create the pull request
    echo "[$(date -Iseconds)] Creating pull request"
    local pr_url
    pr_url=$(gh pr create -R "$repo" \
        --title "Fix #$issue_number: $issue_title" \
        --body "$(cat <<EOF
Addresses #$issue_number

$claude_output

${BOT_SIGNATURE}
EOF
)" \
        --head "$branch_name" 2>&1) || {
        echo "[$(date -Iseconds)] ERROR: Failed to create PR: $pr_url"
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"pr-create-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    echo "[$(date -Iseconds)] PR created: $pr_url"

    write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
        "{\"status\":\"pr-opened\",\"pr_url\":\"$pr_url\",\"work_dir\":\"$repo_dir\",\"processed_at\":\"$(date -Iseconds)\"}"

    gh issue comment "$issue_number" -R "$repo" --body "I've opened a pull request to address this issue: $pr_url

${BOT_SIGNATURE}" 2>/dev/null

    git checkout "$default_branch" 2>/dev/null
    cd - > /dev/null
    release_repo_lock
    return 0
}
