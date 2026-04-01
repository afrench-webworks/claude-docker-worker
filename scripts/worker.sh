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

        # One task per cycle
        exit 0
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

        # One task per cycle
        exit 0
    fi
done
