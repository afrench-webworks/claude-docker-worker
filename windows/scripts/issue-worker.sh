#!/bin/bash
# issue-worker.sh — Picks up new labeled GitHub issues, implements changes
# via Claude Code, and opens a PR. Windows/Git Bash port.
#
# Runs every 30 min via Task Scheduler (work window enforced by the scheduler
# or inside the script). Processes one issue per cycle. Silent when idle.
#
# Windows-specific additions:
#   - AutoMap CLI detection and invocation for documentation build tasks
#   - Paths use $LOCALAPPDATA/claude-docker-worker/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

setup_logging "issue-worker"
ensure_dirs
acquire_lock "issue-worker" || exit 0
load_config

REPO_CACHE_DIR="$WORK_DIR/repos"
mkdir -p "$REPO_CACHE_DIR"

# ---------------------------------------------------------------------------
# AutoMap detection — checks if an issue is an AutoMap build task
# ---------------------------------------------------------------------------
detect_automap_task() {
    local title="$1"
    local body="$2"
    local labels="$3"

    # Check for automap-build label
    if echo "$labels" | jq -r '.[]' 2>/dev/null | grep -qi 'automap'; then
        return 0
    fi

    # Check for AutoMap project file references in body
    if echo "$body" | grep -qiE '\.(waj|wep|wrp|wxsp)\b'; then
        return 0
    fi

    # Check for explicit AutoMap mentions in title
    if echo "$title" | grep -qi 'automap'; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# run_automap_build — invoke AutoMap CLI on Windows
# ---------------------------------------------------------------------------
run_automap_build() {
    local issue_body="$1"

    # Extract project file path from issue body (look for .waj references)
    local project_file
    project_file=$(echo "$issue_body" | grep -oiE '[^\s"<>]+\.(waj|wep|wrp|wxsp)' | head -1)

    if [[ -z "$project_file" ]]; then
        echo "[$(date -Iseconds)] WARN: AutoMap task detected but no project file found in issue body"
        return 1
    fi

    echo "[$(date -Iseconds)] Running AutoMap CLI for project: $project_file"

    # Convert Git Bash path to Windows path for AutoMap CLI
    local win_project_file
    if [[ "$project_file" == /* ]]; then
        win_project_file=$(cygpath -w "$project_file")
    else
        win_project_file="$project_file"
    fi

    # Run AutoMap via cmd.exe (Windows-native executable)
    cmd.exe /c "AutoMap.exe \"$win_project_file\"" 2>&1 || {
        echo "[$(date -Iseconds)] ERROR: AutoMap CLI failed for $win_project_file"
        return 1
    }

    echo "[$(date -Iseconds)] AutoMap build completed for $project_file"
    return 0
}

# ---------------------------------------------------------------------------
# ensure_repo_clone — clone once, fetch on subsequent runs
# Sets $repo_dir to the path of the up-to-date clone.
# ---------------------------------------------------------------------------
ensure_repo_clone() {
    local repo="$1"
    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    repo_dir="$REPO_CACHE_DIR/$dir_name"

    if [[ -d "$repo_dir/.git" ]]; then
        # Existing clone — fetch latest and reset default branch
        cd "$repo_dir"
        git fetch origin 2>&1 || {
            echo "[$(date -Iseconds)] ERROR: Failed to fetch $repo"
            cd - > /dev/null
            return 1
        }

        # Determine default branch (main or master)
        local default_branch
        default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
        if [[ -z "$default_branch" ]]; then
            default_branch="main"
        fi

        git checkout "$default_branch" 2>/dev/null || git checkout -b "$default_branch" "origin/$default_branch" 2>/dev/null
        git reset --hard "origin/$default_branch" 2>/dev/null
        git clean -fd 2>/dev/null
        cd - > /dev/null
    else
        # First time — clone
        echo "[$(date -Iseconds)] Cloning $repo (first time)"
        rm -rf "$repo_dir"
        gh repo clone "$repo" "$repo_dir" 2>&1 || {
            echo "[$(date -Iseconds)] ERROR: Failed to clone $repo"
            return 1
        }
    fi

    # Configure git identity
    cd "$repo_dir"
    git config user.name "$GIT_BOT_NAME"
    git config user.email "$GIT_BOT_EMAIL"
    cd - > /dev/null
    return 0
}

processed_one=false

for repo in "${REPOS[@]}"; do
    if $processed_one; then break; fi
    set_app_token_for_repo "$repo"

    # Get open issues with the trigger label
    issues_json=$(gh issue list -R "$repo" --label "$LABEL" --state open \
        --json number,title,body,labels --jq 'sort_by(.number)' 2>&1) || {
        echo "[$(date -Iseconds)] ERROR: Failed to list issues for $repo: $issues_json"
        continue
    }

    issue_count=$(echo "$issues_json" | jq length)
    [[ "$issue_count" -eq 0 ]] && continue

    for i in $(seq 0 $((issue_count - 1))); do
        issue_number=$(echo "$issues_json" | jq -r ".[$i].number")
        issue_title=$(echo "$issues_json" | jq -r ".[$i].title")
        issue_body=$(echo "$issues_json" | jq -r ".[$i].body")
        issue_labels=$(echo "$issues_json" | jq -r ".[$i].labels | map(.name)")
        state_key="${repo}#${issue_number}"

        # Skip already processed issues — silent
        status=$(read_state_field "$PROCESSED_ISSUES_FILE" "$state_key" "status")
        [[ "$status" == "pr-opened" || "$status" == "in-progress" ]] && continue

        # --- From here on, we have real work to do. Start logging. ---
        echo "[$(date -Iseconds)] Processing $repo#$issue_number: $issue_title"

        # Mark as in-progress
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"in-progress\",\"started_at\":\"$(date -Iseconds)\"}"

        # Acquire repo-level lock to prevent collisions with comment-monitor
        acquire_repo_lock "$repo" || {
            echo "[$(date -Iseconds)] Repo $repo is locked by another process, skipping"
            write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
                "{\"status\":\"pending\",\"reason\":\"repo-locked\",\"processed_at\":\"$(date -Iseconds)\"}"
            continue
        }

        # Ensure we have an up-to-date clone
        ensure_repo_clone "$repo" || {
            write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
                "{\"status\":\"failed\",\"reason\":\"clone-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
            release_repo_lock
            continue
        }

        cd "$repo_dir"

        # Determine default branch
        default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
        [[ -z "$default_branch" ]] && default_branch="main"

        # Create a fresh working branch from the default branch
        branch_name="claude/issue-${issue_number}"

        # Clean up any leftover branch from a previous failed attempt
        git checkout "$default_branch" 2>/dev/null
        git reset --hard "origin/$default_branch" 2>/dev/null
        git clean -fd 2>/dev/null
        git branch -D "$branch_name" 2>/dev/null || true
        git checkout -b "$branch_name"

        # Fetch full issue context including comments
        full_context=$(gh issue view "$issue_number" -R "$repo" \
            --json title,body,comments,labels \
            --jq '{title, body, labels: [.labels[].name], comments: [.comments[] | {author: .author.login, body}]}' 2>&1) || {
            echo "[$(date -Iseconds)] WARN: Could not fetch full issue context, using basic info"
            full_context="{\"title\": \"$issue_title\", \"body\": \"$issue_body\"}"
        }

        # ---------------------------------------------------------------
        # AutoMap task handling — run AutoMap CLI before Claude if needed
        # ---------------------------------------------------------------
        automap_ran=false
        if detect_automap_task "$issue_title" "$issue_body" "$issue_labels"; then
            echo "[$(date -Iseconds)] AutoMap task detected for $repo#$issue_number"
            if run_automap_build "$issue_body"; then
                automap_ran=true
                # Stage AutoMap output so Claude can see what was generated
                git add -A
                if ! git diff --cached --quiet; then
                    git commit -m "AutoMap build output for issue #$issue_number"
                fi
            else
                echo "[$(date -Iseconds)] WARN: AutoMap build failed, continuing with Claude for analysis"
            fi
        fi

        echo "[$(date -Iseconds)] Invoking Claude Code (Opus 4.6)"

        # Build Claude prompt — include AutoMap context if applicable
        automap_context=""
        if $automap_ran; then
            automap_context="

NOTE: An AutoMap build was already executed for this issue. The build output has been
committed to this branch. Review the generated files and make any additional changes
needed (documentation fixes, configuration updates, etc.)."
        fi

        # Invoke Claude Code to implement the changes
        claude_output=$(claude --model opus -p "You are an automated developer working inside a cloned repository.
Your job is to implement changes for a GitHub issue. You have full access to the
codebase and all standard tools (read, write, edit, grep, glob, bash).

Repository: $repo
Issue #$issue_number
${automap_context}
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
            echo "[$(date -Iseconds)] Claude output: $claude_output"
            write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
                "{\"status\":\"failed\",\"reason\":\"claude-failed\",\"processed_at\":\"$(date -Iseconds)\"}"
            gh issue comment "$issue_number" -R "$repo" --body "I attempted to work on this issue but encountered an error during implementation. Here's what happened:

$claude_output

${BOT_SIGNATURE}" 2>/dev/null
            cd - > /dev/null
            release_repo_lock
            continue
        }

        # Check if Claude actually made any changes (beyond AutoMap output)
        if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
            if $automap_ran; then
                echo "[$(date -Iseconds)] AutoMap output committed, no additional Claude changes for $repo#$issue_number"
            else
                echo "[$(date -Iseconds)] No file changes produced for $repo#$issue_number"
                write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
                    "{\"status\":\"needs-clarification\",\"processed_at\":\"$(date -Iseconds)\"}"

                # Post Claude's actual analysis so the human gets actionable feedback
                gh issue comment "$issue_number" -R "$repo" --body "I reviewed this issue and explored the codebase but wasn't able to produce code changes. Here's my analysis:

$claude_output

If you can provide more specific guidance on the approach or which files to modify, I can try again on the next work cycle.

${BOT_SIGNATURE}" 2>/dev/null

                # Return to default branch so the clone is clean for next use
                git checkout "$default_branch" 2>/dev/null
                git branch -D "$branch_name" 2>/dev/null || true
                cd - > /dev/null
                release_repo_lock
                continue
            fi
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
            continue
        }

        # Create the pull request with Claude's summary
        echo "[$(date -Iseconds)] Creating pull request"
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
            continue
        }

        echo "[$(date -Iseconds)] PR created: $pr_url"

        # Update state with PR info and work directory path
        write_state "$PROCESSED_ISSUES_FILE" "$state_key" \
            "{\"status\":\"pr-opened\",\"pr_url\":\"$pr_url\",\"work_dir\":\"$repo_dir\",\"processed_at\":\"$(date -Iseconds)\"}"

        # Comment on the issue with PR link
        gh issue comment "$issue_number" -R "$repo" --body "I've opened a pull request to address this issue: $pr_url

${BOT_SIGNATURE}" 2>/dev/null

        # Return to default branch so the clone is clean for next use
        git checkout "$default_branch" 2>/dev/null
        cd - > /dev/null
        release_repo_lock
        processed_one=true
        break
    done
done
