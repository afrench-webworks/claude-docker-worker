#!/bin/bash
# Boot-time initialization for the GitHub worker feature
set -e

STATE_BASE="/root/workspace/.github-worker"

# Ensure state directories exist on the persistent volume
mkdir -p "$STATE_BASE/state"
mkdir -p "$STATE_BASE/logs"
mkdir -p "$STATE_BASE/locks"
mkdir -p "$STATE_BASE/workdir"

# Initialize state files if they don't exist
[ -f "$STATE_BASE/state/processed-issues.json" ] || echo '{}' > "$STATE_BASE/state/processed-issues.json"
[ -f "$STATE_BASE/state/seen-comments.json" ] || echo '{}' > "$STATE_BASE/state/seen-comments.json"

# Clear stale lock files and WIP state from previous runs/crashes
rm -f "$STATE_BASE/locks/"*.lock
rm -f "$STATE_BASE/state/wip.json"

# Rotate logs — delete log files older than 30 days
find "$STATE_BASE/logs" -name "*.log" -mtime +30 -delete 2>/dev/null || true
