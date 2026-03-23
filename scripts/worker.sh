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

for repo in "${REPOS[@]}"; do
    set_app_token_for_repo "$repo"

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
done
