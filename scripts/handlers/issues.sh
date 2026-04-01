#!/bin/bash
# handlers/issues.sh — Issue handler for the unified worker.
# Uses the dockworker:* label system for workflow management:
#   Priority A: Work on issues with dockworker:ready label
#   Priority B: Evaluate issues with no dockworker:* labels
#
# Per-repo concurrency: if any issue has dockworker:in-progress or
# dockworker:pr-open, this handler yields for that repo.
#
# Uses the Python GitHub module for all API interactions.
#
# Handler interface:
#   handler_issues_priority      — 20 (lower priority than mentions)
#   handler_issues_find_work     — returns first eligible issue as JSON
#   handler_issues_execute       — implements changes or evaluates issue
#   handler_issues_is_in_window  — checks work window

GITHUB_CLI="python3 -m dw_github.cli"

# ===========================================================================
# Handler interface
# ===========================================================================

handler_issues_priority=20

handler_issues_is_in_window() {
    [[ -z "$ISSUE_WORK_WINDOW_START" || -z "$ISSUE_WORK_WINDOW_END" ]] && return 0

    local current_hour
    current_hour=$(date +%-H)

    if [[ "$ISSUE_WORK_WINDOW_START" -le "$ISSUE_WORK_WINDOW_END" ]]; then
        [[ "$current_hour" -ge "$ISSUE_WORK_WINDOW_START" && "$current_hour" -lt "$ISSUE_WORK_WINDOW_END" ]]
    else
        [[ "$current_hour" -ge "$ISSUE_WORK_WINDOW_START" || "$current_hour" -lt "$ISSUE_WORK_WINDOW_END" ]]
    fi
}

handler_issues_find_work() {
    local repo="$1"

    # Find a ready issue to work on (requires no active work — enforced by find-issue)
    local result
    result=$($GITHUB_CLI find-issue --repo "$repo" 2>/dev/null) || true
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    # Evaluation is handled separately by handler_issues_find_evaluation
    # so it can run without a WIP claim (lightweight, read-only triage).
}

# ---------------------------------------------------------------------------
# Evaluation entry point — called from worker.sh outside the WIP gate
# ---------------------------------------------------------------------------
handler_issues_find_evaluation() {
    local repo="$1"

    local result
    result=$($GITHUB_CLI find-unevaluated --repo "$repo" 2>/dev/null) || true
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi
}

handler_issues_execute() {
    local repo="$1"
    local task_json="$2"

    local task_type
    task_type=$(echo "$task_json" | jq -r '.type')

    case "$task_type" in
        issue)
            _execute_issue_work "$repo" "$task_json"
            ;;
        evaluate)
            _execute_issue_evaluation "$repo" "$task_json"
            ;;
        *)
            echo "[$(date -Iseconds)] ERROR: Unknown task type: $task_type"
            return 1
            ;;
    esac
}

# ===========================================================================
# Issue implementation — work on a dockworker:ready issue
# ===========================================================================

_execute_issue_work() {
    local repo="$1"
    local task_json="$2"

    local issue_number issue_title state_key
    issue_number=$(echo "$task_json" | jq -r '.issue_number')
    issue_title=$(echo "$task_json" | jq -r '.issue_title')
    state_key="${repo}#${issue_number}"

    echo "[$(date -Iseconds)] Processing $repo#$issue_number: $issue_title"

    # Mark as in-progress (label transition)
    $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state in-progress 2>/dev/null
    write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
        "{\"status\":\"in-progress\",\"started_at\":\"$(date -Iseconds)\"}"

    # Acquire repo-level lock for git safety
    acquire_repo_lock "$repo" || {
        echo "[$(date -Iseconds)] Repo $repo is locked by another process, skipping"
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state failed 2>/dev/null
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"repo-locked\",\"processed_at\":\"$(date -Iseconds)\"}"
        return 1
    }

    # Ensure we have an up-to-date clone
    ensure_repo_clone "$repo" true || {
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state failed 2>/dev/null
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

    # Fetch full issue context via Python module
    local full_context
    full_context=$($GITHUB_CLI issue-context --repo "$repo" --issue "$issue_number" 2>/dev/null) || {
        echo "[$(date -Iseconds)] WARN: Could not fetch full issue context"
        full_context="{\"title\": \"$issue_title\", \"body\": \"\"}"
    }

    echo "[$(date -Iseconds)] Invoking Claude Code (Opus 4.6)"

    # Invoke Claude Code to implement the changes
    local claude_output
    # shellcheck disable=SC2086
    claude_output=$(claude --model opus $CLAUDE_PLUGIN_FLAGS -p "You are an automated developer working inside a cloned repository.
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
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state failed 2>/dev/null
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"claude-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        local safe_output
        safe_output=$(echo "$claude_output" | sed -E 's/(ghp_|gho_|github_pat_|ghs_)[A-Za-z0-9_]+/[REDACTED]/g')
        $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
            --body "I attempted to work on this issue but encountered an error during implementation. Here's what happened:

$safe_output

${BOT_SIGNATURE}" 2>/dev/null
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    # Check if Claude actually made any changes
    if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        echo "[$(date -Iseconds)] No file changes produced for $repo#$issue_number"
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state needs-info 2>/dev/null
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"needs-clarification\",\"processed_at\":\"$(date -Iseconds)\"}"

        $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
            --body "I reviewed this issue and explored the codebase but wasn't able to produce code changes. Here's my analysis:

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
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state failed 2>/dev/null
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"push-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    # Create the pull request via Python module
    echo "[$(date -Iseconds)] Creating pull request"
    local pr_result
    pr_result=$($GITHUB_CLI create-pr --repo "$repo" --head "$branch_name" \
        --title "Fix #$issue_number: $issue_title" \
        --body "Addresses #$issue_number

$claude_output

${BOT_SIGNATURE}" 2>&1) || {
        echo "[$(date -Iseconds)] ERROR: Failed to create PR: $pr_result"
        $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state failed 2>/dev/null
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"failed\",\"reason\":\"pr-create-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
        cd - > /dev/null
        release_repo_lock
        return 1
    }

    local pr_url
    pr_url=$(echo "$pr_result" | jq -r '.pr_url')
    echo "[$(date -Iseconds)] PR created: $pr_url"

    # Transition labels: in-progress → pr-open
    $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state pr-open 2>/dev/null
    write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
        "{\"status\":\"pr-opened\",\"pr_url\":\"$pr_url\",\"work_dir\":\"$repo_dir\",\"processed_at\":\"$(date -Iseconds)\"}"

    $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
        --body "I've opened a pull request to address this issue: $pr_url

${BOT_SIGNATURE}" 2>/dev/null

    git checkout "$default_branch" 2>/dev/null
    cd - > /dev/null
    release_repo_lock
    return 0
}

# ===========================================================================
# Issue evaluation — triage an unevaluated issue
# ===========================================================================

_execute_issue_evaluation() {
    local repo="$1"
    local task_json="$2"

    local issue_number issue_title
    issue_number=$(echo "$task_json" | jq -r '.issue_number')
    issue_title=$(echo "$task_json" | jq -r '.issue_title')

    echo "[$(date -Iseconds)] Evaluating $repo#$issue_number: $issue_title"

    # Mark as evaluating so the next cron cycle doesn't pick up the same issue
    $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state evaluating 2>/dev/null

    # Fetch full issue context
    local full_context
    full_context=$($GITHUB_CLI issue-context --repo "$repo" --issue "$issue_number" 2>/dev/null) || {
        echo "[$(date -Iseconds)] WARN: Could not fetch issue context for evaluation"
        return 1
    }

    # Ensure we have a repo clone for Claude to explore
    ensure_repo_clone "$repo" || return 1

    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    local readonly_workdir="$WORK_DIR/readonly-${dir_name}-eval-$$"
    cp -a "$repo_dir"/. "$readonly_workdir"/
    rm -rf "$readonly_workdir/.git"

    cd "$readonly_workdir"

    # Ask Claude to evaluate the issue
    local claude_output
    claude_output=$(claude --model opus -p "You are an automated assistant evaluating a GitHub issue for readiness.
Your job is to determine if this issue is ready for an AI developer to implement.

Repository: $repo
Issue #$issue_number

Full issue context:
$full_context

Evaluate this issue and respond with EXACTLY ONE of these verdicts on the FIRST LINE
of your response, followed by your reasoning:

READY — The issue is clear, specific, and actionable. An AI developer could implement
it without needing additional information.

NEEDS_INFO — The issue needs clarification before work can begin. After your reasoning,
include a section titled 'Questions:' with specific questions that need answers.

SKIP — The issue is not suitable for AI implementation (e.g., requires human judgment,
access to external systems, is a discussion/question, or is too vague to act on).

Your reasoning should address:
- Is the desired outcome clearly described?
- Are there specific files, components, or areas of the codebase identified?
- Is the scope manageable for a single implementation pass?
- Are there any blockers or dependencies that need human intervention?" 2>&1) || {
        echo "[$(date -Iseconds)] ERROR: Claude evaluation failed for $repo#$issue_number"
        cd - > /dev/null
        rm -rf "$readonly_workdir"
        return 1
    }

    cd - > /dev/null
    rm -rf "$readonly_workdir"

    # Parse the verdict from Claude's output
    local verdict
    verdict=$(echo "$claude_output" | head -1 | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')

    case "$verdict" in
        READY*)
            echo "[$(date -Iseconds)] Issue $repo#$issue_number evaluated as READY"
            $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state ready 2>/dev/null
            $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
                --body "I've evaluated this issue and it looks ready for implementation. I'll pick it up on a future work cycle.

${BOT_SIGNATURE}" 2>/dev/null
            ;;
        NEEDS_INFO*|NEEDS-INFO*)
            echo "[$(date -Iseconds)] Issue $repo#$issue_number needs more information"
            $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state needs-info 2>/dev/null

            # Extract questions from Claude's output
            local questions
            questions=$(echo "$claude_output" | sed -n '/^Questions:/,$p')
            [[ -z "$questions" ]] && questions="$claude_output"

            $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
                --body "I've evaluated this issue and have some questions before I can work on it:

$questions

Once these are addressed, I'll re-evaluate the issue.

${BOT_SIGNATURE}" 2>/dev/null
            ;;
        SKIP*)
            echo "[$(date -Iseconds)] Issue $repo#$issue_number skipped (not suitable for AI)"
            $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state skip 2>/dev/null
            $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
                --body "I've evaluated this issue and determined it's not suitable for automated implementation at this time.

$(echo "$claude_output" | tail -n +2)

${BOT_SIGNATURE}" 2>/dev/null
            ;;
        *)
            echo "[$(date -Iseconds)] WARN: Could not parse evaluation verdict for $repo#$issue_number, marking as needs-info"
            $GITHUB_CLI mark-issue --repo "$repo" --issue "$issue_number" --state needs-info 2>/dev/null
            $GITHUB_CLI comment --repo "$repo" --issue "$issue_number" \
                --body "I attempted to evaluate this issue but couldn't determine a clear verdict. Here's my analysis:

$claude_output

${BOT_SIGNATURE}" 2>/dev/null
            ;;
    esac
}
