#!/bin/bash
# plugin-flags.sh — Discovers installed Claude Code plugins and builds
# --plugin-dir flags for claude invocations. Source this from any feature
# script that calls `claude -p`.
#
# Usage:
#   source /opt/dockworker/plugin-flags.sh
#   _discover_plugins
#   claude $CLAUDE_PLUGIN_FLAGS -p "..."

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
