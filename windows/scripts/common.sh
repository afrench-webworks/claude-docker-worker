#!/bin/bash
# common.sh — Shared utilities for the issue worker system (Windows/Git Bash)
#
# This is the Windows-native port of the Linux common.sh. Key differences:
#   - Paths use $USERPROFILE instead of /root
#   - State lives in $LOCALAPPDATA/claude-docker-worker instead of /root/workspace
#   - flock replaced with mkdir-based locking (atomic on NTFS)
#   - All paths converted via cygpath for Git Bash compatibility
set -euo pipefail

# ---------------------------------------------------------------------------
# Path setup — resolve Windows paths for Git Bash
# ---------------------------------------------------------------------------

# Convert Windows paths to Git Bash paths
_HOME="$(cygpath "$USERPROFILE")"
_LOCALAPPDATA="$(cygpath "$LOCALAPPDATA")"

WORKER_DIR="$_LOCALAPPDATA/claude-docker-worker"
CONFIG_FILE="${WORKER_CONFIG_FILE:-$WORKER_DIR/config.yaml}"
STATE_DIR="$WORKER_DIR/state"
LOG_DIR="$WORKER_DIR/logs"
LOCK_DIR="$WORKER_DIR/locks"
WORK_DIR="$WORKER_DIR/workdir"

PROCESSED_ISSUES_FILE="$STATE_DIR/processed-issues.json"
SEEN_COMMENTS_FILE="$STATE_DIR/seen-comments.json"

# ---------------------------------------------------------------------------
# Config loading — lightweight YAML parsing (no external deps beyond grep/sed)
# ---------------------------------------------------------------------------

declare -a REPOS=()
declare -a AUTHORIZED_USERS=()
LABEL=""
MENTION=""
BOT_SIGNATURE=""
GIT_BOT_NAME=""
GIT_BOT_EMAIL=""
APP_ID=""

# Helper to parse a scalar value from config.yaml
_parse_config_value() {
    local key="$1"
    local raw
    raw=$(grep "^${key}:" "$CONFIG_FILE" | sed 's/\r$//' | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//')
    # Strip surrounding quotes
    if [[ "${raw:0:1}" == '"' && "${raw: -1}" == '"' ]]; then
        raw="${raw:1:${#raw}-2}"
    elif [[ "${raw:0:1}" == "'" && "${raw: -1}" == "'" ]]; then
        raw="${raw:1:${#raw}-2}"
    fi
    echo "$raw"
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[ERROR] Config file not found: $CONFIG_FILE"
        echo "[ERROR] Copy config.yaml.example to $CONFIG_FILE and customize it."
        return 1
    fi

    # Parse repos list (lines starting with "  - ")
    REPOS=()
    while IFS= read -r line; do
        repo=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*#.*//')
        [[ -n "$repo" ]] && REPOS+=("$repo")
    done < <(grep -A 100 '^repos:' "$CONFIG_FILE" | tail -n +2 | grep '^[[:space:]]*-' | grep -v '^[[:space:]]*#')

    # Parse authorized_users list (same format as repos)
    AUTHORIZED_USERS=()
    while IFS= read -r line; do
        user=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*#.*//')
        [[ -n "$user" ]] && AUTHORIZED_USERS+=("$user")
    done < <(grep -A 100 '^authorized_users:' "$CONFIG_FILE" | tail -n +2 | grep '^[[:space:]]*-' | grep -v '^[[:space:]]*#')

    LABEL=$(_parse_config_value "label")
    MENTION=$(_parse_config_value "mention")
    BOT_SIGNATURE=$(_parse_config_value "bot_signature")
    GIT_BOT_NAME=$(_parse_config_value "git_bot_name")
    GIT_BOT_EMAIL=$(_parse_config_value "git_bot_email")
    if [[ ${#REPOS[@]} -eq 0 ]]; then
        echo "[ERROR] No repos configured in $CONFIG_FILE"
        return 1
    fi
    if [[ -z "$LABEL" ]]; then
        echo "[ERROR] No label configured in $CONFIG_FILE"
        return 1
    fi
    if [[ ${#AUTHORIZED_USERS[@]} -eq 0 ]]; then
        echo "[ERROR] No authorized_users configured in $CONFIG_FILE"
        return 1
    fi

    # GitHub App config (optional — falls back to gh CLI auth if not set)
    APP_ID=$(_parse_config_value "app_id")

    # Source the token script and discover installations
    source "$SCRIPT_DIR/github-app-token.sh"
    init_app_auth "$APP_ID" || {
        echo "[WARN] GitHub App init failed, falling back to gh CLI auth"
    }

    # Config loaded silently — only errors are logged
}

# ---------------------------------------------------------------------------
# Locking — mkdir-based locking (replaces flock, atomic on NTFS)
#
# mkdir is atomic on both NTFS and most filesystems. If the directory
# already exists, mkdir fails — acting as a lock acquire failure.
# ---------------------------------------------------------------------------

acquire_lock() {
    local lock_name="$1"
    local lock_dir="$LOCK_DIR/${lock_name}.lock"
    mkdir -p "$LOCK_DIR"

    if mkdir "$lock_dir" 2>/dev/null; then
        # Write PID for debugging
        echo $$ > "$lock_dir/pid"
        # Register cleanup on exit
        trap "rm -rf '$lock_dir'" EXIT
        return 0
    else
        return 1
    fi
}

# Acquire a per-repo lock to prevent comment-monitor and issue-worker
# from touching the same repo clone simultaneously.
# Non-blocking — returns 1 if another process holds the lock.
acquire_repo_lock() {
    local repo="$1"
    local lock_name
    lock_name="repo-$(echo "$repo" | tr '/' '-')"
    local lock_dir="$LOCK_DIR/${lock_name}.lock"
    mkdir -p "$LOCK_DIR"

    if mkdir "$lock_dir" 2>/dev/null; then
        echo $$ > "$lock_dir/pid"
        _REPO_LOCK_DIR="$lock_dir"
        return 0
    else
        return 1
    fi
}

release_repo_lock() {
    if [[ -n "${_REPO_LOCK_DIR:-}" && -d "$_REPO_LOCK_DIR" ]]; then
        rm -rf "$_REPO_LOCK_DIR"
        _REPO_LOCK_DIR=""
    fi
}

# ---------------------------------------------------------------------------
# Logging — tee-based output to dated log files
# ---------------------------------------------------------------------------

setup_logging() {
    local script_name="$1"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/${script_name}-$(date +%Y-%m-%d).log"

    exec > >(tee -a "$LOG_FILE") 2>&1
}

# ---------------------------------------------------------------------------
# State management — JSON read/write via jq
# ---------------------------------------------------------------------------

read_state() {
    local file="$1"
    local key="$2"
    local query="${3:-.}"

    if [[ ! -f "$file" ]]; then
        echo "null"
        return
    fi

    # Keys contain "/" and "#" so we use --arg for safe lookup
    jq -r --arg k "$key" '.[$k] // "null"' "$file" 2>/dev/null || echo "null"
}

read_state_field() {
    local file="$1"
    local key="$2"
    local field="$3"

    if [[ ! -f "$file" ]]; then
        echo "null"
        return
    fi

    jq -r --arg k "$key" --arg f "$field" '.[$k][$f] // "null"' "$file" 2>/dev/null || echo "null"
}

write_state() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        echo '{}' > "$file"
    fi

    local tmp="${file}.tmp"
    jq --arg k "$key" --argjson v "$value" '.[$k] = $v' "$file" > "$tmp" && mv "$tmp" "$file"
}

write_state_scalar() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "$file" ]]; then
        echo '{}' > "$file"
    fi

    local tmp="${file}.tmp"
    jq --arg k "$key" --arg v "$value" '.[$k] = ($v | tonumber)' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Bot comment detection — checks for bot signature in comment body
# ---------------------------------------------------------------------------

is_bot_comment() {
    local comment_body="$1"

    [[ "$comment_body" == *"$BOT_SIGNATURE"* ]]
}

has_mention() {
    local comment_body="$1"

    [[ "$comment_body" == *"$MENTION"* ]]
}

is_authorized_user() {
    local username="$1"
    local user
    for user in "${AUTHORIZED_USERS[@]}"; do
        [[ "$user" == "$username" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Ensure directories exist
# ---------------------------------------------------------------------------

ensure_dirs() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$LOCK_DIR" "$WORK_DIR"
    [[ -f "$PROCESSED_ISSUES_FILE" ]] || echo '{}' > "$PROCESSED_ISSUES_FILE"
    [[ -f "$SEEN_COMMENTS_FILE" ]] || echo '{}' > "$SEEN_COMMENTS_FILE"
}
