#!/bin/bash
# common.sh — Shared utilities for the issue worker system
set -euo pipefail

CONFIG_FILE="/opt/issue-worker/config.yaml"
STATE_DIR="/root/workspace/.issue-worker/state"
LOG_DIR="/root/workspace/.issue-worker/logs"
LOCK_DIR="/root/workspace/.issue-worker/locks"
WORK_DIR="/root/workspace/.issue-worker/workdir"
REPO_CACHE_DIR="$WORK_DIR/repos"

PROCESSED_ISSUES_FILE="$STATE_DIR/processed-issues.json"
SEEN_COMMENTS_FILE="$STATE_DIR/seen-comments.json"
WIP_FILE="$STATE_DIR/wip.json"

# ---------------------------------------------------------------------------
# Config loading — lightweight YAML parsing (no external deps beyond grep/sed)
# ---------------------------------------------------------------------------

declare -a REPOS=()
declare -a AUTHORIZED_USERS=()
MENTION=""
BOT_SIGNATURE=""
GIT_BOT_NAME=""
GIT_BOT_EMAIL=""
APP_ID=""
LABEL_PREFIX=""
CLAUDE_ISSUE_EVAL_FLAGS=""
CLAUDE_ISSUE_WORK_FLAGS=""
CLAUDE_MENTION_REPLY_FLAGS=""

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

# Parse a value from nested YAML (3 levels: section > subsection > key)
# Usage: _parse_nested_config "claude" "issue_evaluation" "model"
_parse_nested_config() {
    local section="$1"
    local subsection="$2"
    local key="$3"
    awk -v section="$section" -v subsection="$subsection" -v key="$key" '
        BEGIN { in_sec=0; in_sub=0 }
        /^[^ #]/ { in_sec=0; in_sub=0 }
        $0 ~ "^" section ":" { in_sec=1; next }
        in_sec && /^  [^ #]/ { in_sub=0 }
        in_sec && $0 ~ "^  " subsection ":" { in_sub=1; next }
        in_sub && $0 ~ "^    " key ":" {
            val = $0
            sub(/^    [^:]+:[[:space:]]*/, "", val)
            sub(/[[:space:]]*#.*$/, "", val)
            if (val ~ /^".*"$/) val = substr(val, 2, length(val)-2)
            if (val ~ /^'"'"'.*'"'"'$/) val = substr(val, 2, length(val)-2)
            print val
            exit
        }
    ' "$CONFIG_FILE"
}

# Build Claude CLI flags (--model, --effort) for a given task type
_claude_flags_for() {
    local task_type="$1"
    local model effort flags

    model=$(_parse_nested_config "claude" "$task_type" "model")
    [[ -z "$model" ]] && model="opus"
    flags="--model $model"

    effort=$(_parse_nested_config "claude" "$task_type" "effort")
    [[ -n "$effort" ]] && flags="$flags --effort $effort"

    echo "$flags"
}

load_config() {
    # _parse_yaml_list — extract list items under a top-level key, stopping at the next key
    _parse_yaml_list() {
        local key="$1"
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^${key}: ]]; then
                in_section=true
                continue
            fi
            # Stop at the next top-level key (non-indented, non-blank, non-comment)
            if $in_section && [[ "$line" =~ ^[^[:space:]#] ]]; then
                break
            fi
            if $in_section && [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                local value
                value=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/[[:space:]]*#.*//')
                [[ -n "$value" ]] && echo "$value"
            fi
        done < "$CONFIG_FILE"
    }

    REPOS=()
    while IFS= read -r repo; do
        REPOS+=("$repo")
    done < <(_parse_yaml_list "repos")

    AUTHORIZED_USERS=()
    while IFS= read -r user; do
        AUTHORIZED_USERS+=("$user")
    done < <(_parse_yaml_list "authorized_users")

    MENTION=$(_parse_config_value "mention")
    BOT_SIGNATURE=$(_parse_config_value "bot_signature")
    GIT_BOT_NAME=$(_parse_config_value "git_bot_name")
    GIT_BOT_EMAIL=$(_parse_config_value "git_bot_email")
    LABEL_PREFIX=$(_parse_config_value "label_prefix")
    [[ -z "$LABEL_PREFIX" ]] && LABEL_PREFIX="dockworker"

    if [[ ${#REPOS[@]} -eq 0 ]]; then
        echo "[ERROR] No repos configured in $CONFIG_FILE"
        return 1
    fi
    if [[ ${#AUTHORIZED_USERS[@]} -eq 0 ]]; then
        echo "[ERROR] No authorized_users configured in $CONFIG_FILE"
        return 1
    fi

    # Work window for issue handler (optional — runs 24/7 if not set)
    ISSUE_WORK_WINDOW_START=$(_parse_config_value "issue_work_window_start")
    ISSUE_WORK_WINDOW_END=$(_parse_config_value "issue_work_window_end")

    # GitHub App config (optional — falls back to gh CLI auth if not set)
    APP_ID=$(_parse_config_value "app_id")

    # Auth is now handled by the Python GitHub module (scripts/dw_github/auth.py).
    # Token injection into settings.json happens via: python3 -m dw_github.cli auth --owner <owner>

    # Claude settings per task type (model + effort)
    CLAUDE_ISSUE_EVAL_FLAGS=$(_claude_flags_for "issue_evaluation")
    CLAUDE_ISSUE_WORK_FLAGS=$(_claude_flags_for "issue_work")
    CLAUDE_MENTION_REPLY_FLAGS=$(_claude_flags_for "mention_reply")

    # Discover installed plugins
    _discover_plugins

    # Config loaded silently — only errors are logged
}

# ---------------------------------------------------------------------------
# Plugin discovery — builds --plugin-dir flags from installed_plugins.json
# ---------------------------------------------------------------------------

PLUGINS_FILE="/root/.claude/plugins/installed_plugins.json"
CLAUDE_PLUGIN_FLAGS=""

_discover_plugins() {
    CLAUDE_PLUGIN_FLAGS=""
    [[ ! -f "$PLUGINS_FILE" ]] && return 0

    local plugin_dirs
    plugin_dirs=$(jq -r '.[] | .directory // empty' "$PLUGINS_FILE" 2>/dev/null) || return 0

    while IFS= read -r dir; do
        [[ -z "$dir" || ! -d "$dir" ]] && continue
        CLAUDE_PLUGIN_FLAGS="$CLAUDE_PLUGIN_FLAGS --plugin-dir $dir"
    done <<< "$plugin_dirs"

    if [[ -n "$CLAUDE_PLUGIN_FLAGS" ]]; then
        echo "[$(date -Iseconds)] Discovered plugins:$CLAUDE_PLUGIN_FLAGS"
    fi
}

# ---------------------------------------------------------------------------
# Repo clone management — unified clone with optional fresh fetch
# ---------------------------------------------------------------------------

# ensure_repo_clone — clone once, optionally fetch+reset on subsequent runs.
# Sets global $repo_dir to the path of the clone.
#   ensure_repo_clone "owner/repo"        — reuse existing clone as-is
#   ensure_repo_clone "owner/repo" true   — fetch origin and reset to default branch
ensure_repo_clone() {
    local repo="$1"
    local fresh="${2:-false}"
    local dir_name
    dir_name="$(echo "$repo" | tr '/' '-')"
    repo_dir="$REPO_CACHE_DIR/$dir_name"

    if [[ -d "$repo_dir/.git" ]]; then
        if [[ "$fresh" == "true" ]]; then
            cd "$repo_dir"
            git fetch origin 2>&1 || {
                echo "[$(date -Iseconds)] ERROR: Failed to fetch $repo"
                cd - > /dev/null
                return 1
            }

            local default_branch
            default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
            [[ -z "$default_branch" ]] && default_branch="main"

            git checkout "$default_branch" 2>/dev/null || git checkout -b "$default_branch" "origin/$default_branch" 2>/dev/null
            git reset --hard "origin/$default_branch" 2>/dev/null
            git clean -fd 2>/dev/null
            cd - > /dev/null
        fi
    else
        mkdir -p "$REPO_CACHE_DIR"
        echo "[$(date -Iseconds)] Cloning $repo (first time)"
        rm -rf "$repo_dir"
        gh repo clone "$repo" "$repo_dir" 2>&1 || {
            echo "[$(date -Iseconds)] ERROR: Failed to clone $repo"
            return 1
        }
    fi

    cd "$repo_dir"
    git config user.name "$GIT_BOT_NAME"
    git config user.email "$GIT_BOT_EMAIL"
    cd - > /dev/null
    return 0
}

# ---------------------------------------------------------------------------
# WIP tracking — per-repo work-in-progress state across cron cycles
# ---------------------------------------------------------------------------

WIP_LOCK_FD=202

is_repo_wip() {
    local repo="$1"
    [[ ! -f "$WIP_FILE" ]] && return 1

    local started_at
    started_at=$(jq -r --arg r "$repo" '.[$r].started_at // empty' "$WIP_FILE" 2>/dev/null)
    [[ -n "$started_at" ]]
}

set_repo_wip() {
    local repo="$1"
    local task_type="$2"
    [[ ! -f "$WIP_FILE" ]] && echo '{}' > "$WIP_FILE"

    local tmp="${WIP_FILE}.tmp"
    jq --arg r "$repo" --arg t "$task_type" --arg s "$(date -Iseconds)" \
        '.[$r] = {task_type: $t, started_at: $s}' "$WIP_FILE" > "$tmp" && mv "$tmp" "$WIP_FILE"
}

clear_repo_wip() {
    local repo="$1"
    [[ ! -f "$WIP_FILE" ]] && return 0

    local tmp="${WIP_FILE}.tmp"
    jq --arg r "$repo" 'del(.[$r])' "$WIP_FILE" > "$tmp" && mv "$tmp" "$WIP_FILE"
}

# Atomic check-and-set: returns 0 if repo was claimed, 1 if already WIP.
try_claim_repo() {
    local repo="$1"
    local task_type="$2"

    (
        eval "exec $WIP_LOCK_FD>\"$LOCK_DIR/wip.lock\""
        flock $WIP_LOCK_FD

        if is_repo_wip "$repo"; then
            exit 1
        fi
        set_repo_wip "$repo" "$task_type"
    )
}

# ---------------------------------------------------------------------------
# Locking — prevents overlapping runs and repo contention
# ---------------------------------------------------------------------------

LOCK_FD=200
REPO_LOCK_FD=201

acquire_lock() {
    local lock_name="$1"
    local lock_file="$LOCK_DIR/${lock_name}.lock"
    mkdir -p "$LOCK_DIR"

    eval "exec $LOCK_FD>\"$lock_file\""
    if ! flock -n $LOCK_FD; then
        return 1
    fi
}

# Acquire a per-repo lock to prevent concurrent worker processes
# from touching the same repo clone simultaneously.
# Non-blocking — returns 1 if another process holds the lock.
acquire_repo_lock() {
    local repo="$1"
    local lock_name
    lock_name="repo-$(echo "$repo" | tr '/' '-')"
    local lock_file="$LOCK_DIR/${lock_name}.lock"
    mkdir -p "$LOCK_DIR"

    eval "exec $REPO_LOCK_FD>\"$lock_file\""
    if ! flock -n $REPO_LOCK_FD; then
        return 1
    fi
}

release_repo_lock() {
    eval "exec $REPO_LOCK_FD>&-" 2>/dev/null || true
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
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$LOCK_DIR" "$WORK_DIR" "$REPO_CACHE_DIR"
    [[ -f "$PROCESSED_ISSUES_FILE" ]] || echo '{}' > "$PROCESSED_ISSUES_FILE"
    [[ -f "$SEEN_COMMENTS_FILE" ]] || echo '{}' > "$SEEN_COMMENTS_FILE"
    [[ -f "$WIP_FILE" ]] || echo '{}' > "$WIP_FILE"
}
