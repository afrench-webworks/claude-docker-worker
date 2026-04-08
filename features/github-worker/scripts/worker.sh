#!/bin/bash
# worker.sh — Unified work loop for the Claude Docker Worker.
# Runs every N minutes via cron. On each cycle, scans all configured repos
# for actionable work (mentions, labeled issues, etc.), picks the highest-
# priority task, and executes it. Processes one task per cycle.
#
# No global script lock — multiple worker processes can coexist, coordinated
# by per-repo WIP tracking and repo-level flock.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

setup_logging "worker"
ensure_dirs
load_config

# Source all handlers (priority-ordered)
source "$SCRIPT_DIR/handlers/mentions.sh"
source "$SCRIPT_DIR/handlers/issues.sh"

HANDLERS=("mentions" "issues")

# Clean up stale readonly temp dirs (older than 1 hour)
find "$WORK_DIR" -maxdepth 1 -name "readonly-*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null

GITHUB_CLI="python3 -m dw_github.cli"

for repo in "${REPOS[@]}"; do
    # Authenticate via Python module
    owner=$(echo "$repo" | cut -d'/' -f1)
    $GITHUB_CLI auth --owner "$owner" 2>/dev/null || true

    # Ensure dockworker labels exist (idempotent, runs every cycle)
    $GITHUB_CLI ensure-labels --repo "$repo" 2>/dev/null || {
        echo "[$(date -Iseconds)] WARN: Could not ensure labels for $repo (repo may not exist or auth failed), skipping"
        continue
    }

    # Reset check: strip all dockworker state from issues with dockworker:reset
    reset_result=$($GITHUB_CLI process-resets --repo "$repo" 2>/dev/null) || true
    if [[ -n "$reset_result" ]]; then
        for issue_num in $(echo "$reset_result" | jq -r '.resets[].issue // empty' 2>/dev/null); do
            state_key="${repo}#${issue_num}"
            if [[ -f "$PROCESSED_ISSUES_FILE" ]]; then
                tmp="${PROCESSED_ISSUES_FILE}.tmp"
                jq --arg k "$state_key" 'del(.[$k])' "$PROCESSED_ISSUES_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_ISSUES_FILE"
            fi
            # Delete stale remote branch so the next implementation attempt doesn't conflict
            branch_name="claude/issue-${issue_num}"
            repo_dir="$REPO_CACHE_DIR/$(echo "$repo" | tr '/' '-')"
            if [[ -d "$repo_dir/.git" ]]; then
                git -C "$repo_dir" push origin --delete "$branch_name" 2>/dev/null || true
            fi
            echo "[$(date -Iseconds)] Reset: cleared state for $state_key"
        done
    fi

    # Lifecycle check: transition pr-open → done/failed when PRs are merged/closed
    lifecycle_result=$($GITHUB_CLI check-pr-lifecycle --repo "$repo" 2>/dev/null) || true
    if [[ -n "$lifecycle_result" ]]; then
        for row in $(echo "$lifecycle_result" | jq -c '.transitions[]' 2>/dev/null); do
            issue_num=$(echo "$row" | jq -r '.issue')
            status=$(echo "$row" | jq -r '.status')
            state_key="${repo}#${issue_num}"

            # Clean up branches for completed/failed work
            branch_name="claude/issue-${issue_num}"
            repo_dir="$REPO_CACHE_DIR/$(echo "$repo" | tr '/' '-')"
            if [[ -d "$repo_dir/.git" ]]; then
                git -C "$repo_dir" branch -D "$branch_name" 2>/dev/null || true
                git -C "$repo_dir" push origin --delete "$branch_name" 2>/dev/null || true
            fi

            # Clear processed-issues state for done work (no longer needed)
            if [[ "$status" == "merged" || "$status" == "closed" || "$status" == "closed-without-merge" ]]; then
                if [[ -f "$PROCESSED_ISSUES_FILE" ]]; then
                    tmp="${PROCESSED_ISSUES_FILE}.tmp"
                    jq --arg k "$state_key" 'del(.[$k])' "$PROCESSED_ISSUES_FILE" > "$tmp" && mv "$tmp" "$PROCESSED_ISSUES_FILE"
                fi
            fi

            echo "[$(date -Iseconds)] Lifecycle: $state_key → $status (cleaned up)"
        done
    fi

    # --- WIP-gated handlers (mentions, issue implementation) ---
    for handler in "${HANDLERS[@]}"; do
        # Check work window
        window_fn="handler_${handler}_is_in_window"
        if declare -F "$window_fn" > /dev/null 2>&1; then
            "$window_fn" || continue
        fi

        # Find work
        task=$("handler_${handler}_find_work" "$repo" || true)
        [[ -z "$task" ]] && continue

        # Claim repo (atomic check-and-set)
        try_claim_repo "$repo" "$handler" || {
            echo "[$(date -Iseconds)] Repo $repo has work in progress, skipping"
            continue
        }

        # Execute
        "handler_${handler}_execute" "$repo" "$task" || true
        clear_repo_wip "$repo"

        # One task per repo per cycle
        break
    done

    # --- Issue evaluation (no WIP claim needed — lightweight, read-only triage) ---
    # This runs even if the repo has active work (in-progress PR, etc.)
    if declare -F "handler_issues_is_in_window" > /dev/null 2>&1; then
        handler_issues_is_in_window || continue
    fi

    eval_task=$(handler_issues_find_evaluation "$repo" || true)
    if [[ -n "$eval_task" ]]; then
        echo "[$(date -Iseconds)] Evaluating unevaluated issue in $repo"
        handler_issues_execute "$repo" "$eval_task" || true

        # One task per repo per cycle
        continue
    fi
done

# --- Global cleanup (runs once per cycle, not per-repo) ---
# Prune handled-mention entries older than 30 days
$GITHUB_CLI prune-mentions 2>/dev/null || true
