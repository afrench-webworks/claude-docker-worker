#!/bin/bash
# github-app-token.sh — Generates GitHub App installation access tokens.
# Automatically discovers all installations and caches tokens per-installation.
# Tokens are valid for 1 hour; cache reuses them for up to 50 minutes.
#
# Usage: source this file from common.sh, then call:
#   init_app_auth "$APP_ID"          — discovers installations (run once at startup)
#   set_app_token_for_repo "owner/repo" — sets GH_TOKEN for the repo's owner
#
# If no GitHub App is configured, all functions are no-ops and fall back
# to existing gh CLI auth silently.

APP_KEY_FILE="/root/.claude/github-app-key.pem"
TOKEN_CACHE_DIR="/root/.claude/app-token-cache"
CLAUDE_SETTINGS_FILE="/root/.claude/settings.json"

# Associative array: owner -> installation_id
declare -A _APP_INSTALLATIONS=()
_APP_CONFIGURED=false

# ---------------------------------------------------------------------------
# _generate_jwt — Create a signed JWT for GitHub App authentication
# ---------------------------------------------------------------------------
_generate_jwt() {
    local app_id="$1"
    local now
    now=$(date +%s)
    local iat=$((now - 60))
    local exp=$((now + 600))

    local header
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr "+/" "-_" | tr -d "=")
    local payload
    payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | openssl base64 -e -A | tr "+/" "-_" | tr -d "=")
    local signature
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$APP_KEY_FILE" | openssl base64 -e -A | tr "+/" "-_" | tr -d "=")

    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# ---------------------------------------------------------------------------
# init_app_auth — Discover all installations for this app.
# Call once at startup. Populates _APP_INSTALLATIONS map.
# ---------------------------------------------------------------------------
init_app_auth() {
    local app_id="$1"

    if [[ -z "$app_id" || ! -f "$APP_KEY_FILE" ]]; then
        return 0
    fi

    mkdir -p "$TOKEN_CACHE_DIR"
    _APP_CONFIGURED=true

    local jwt
    jwt=$(_generate_jwt "$app_id")

    local response
    response=$(curl -s \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations")

    # Parse each installation: map account login -> installation id
    local count
    count=$(echo "$response" | jq 'length' 2>/dev/null) || count=0

    for i in $(seq 0 $((count - 1))); do
        local owner
        owner=$(echo "$response" | jq -r ".[$i].account.login")
        local inst_id
        inst_id=$(echo "$response" | jq -r ".[$i].id")
        _APP_INSTALLATIONS["$owner"]="$inst_id"
    done

    if [[ ${#_APP_INSTALLATIONS[@]} -eq 0 ]]; then
        echo "[$(date -Iseconds)] WARN: GitHub App has no installations" >&2
        _APP_CONFIGURED=false
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _get_installation_token — Exchange JWT for an installation access token
# ---------------------------------------------------------------------------
_get_installation_token() {
    local app_id="$1"
    local installation_id="$2"

    local jwt
    jwt=$(_generate_jwt "$app_id")

    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens")

    local token
    token=$(echo "$response" | jq -r '.token // empty')

    if [[ -z "$token" ]]; then
        # Log only the error message, not the full API response (may contain tokens)
        local error_msg
        error_msg=$(echo "$response" | jq -r '.message // "unknown error"' 2>/dev/null)
        echo "[$(date -Iseconds)] ERROR: Failed to get installation token: $error_msg" >&2
        return 1
    fi

    local expires_at
    expires_at=$(echo "$response" | jq -r '.expires_at')

    # Cache per installation
    local cache_file="$TOKEN_CACHE_DIR/${installation_id}.json"
    printf '{"token":"%s","expires_at":"%s"}' "$token" "$expires_at" > "$cache_file"
    chmod 600 "$cache_file"

    echo "$token"
}

# ---------------------------------------------------------------------------
# _inject_token_into_settings — Write GH_TOKEN into Claude's settings.json env
# ---------------------------------------------------------------------------
_inject_token_into_settings() {
    local token="$1"
    if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
        return 0
    fi
    local tmp="${CLAUDE_SETTINGS_FILE}.tmp"
    jq --arg t "$token" '.env.GH_TOKEN = $t' "$CLAUDE_SETTINGS_FILE" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# _clear_token_from_settings — Remove GH_TOKEN from settings.json so gh CLI
# auth takes over when app token refresh fails
# ---------------------------------------------------------------------------
_clear_token_from_settings() {
    if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
        return 0
    fi
    local tmp="${CLAUDE_SETTINGS_FILE}.tmp"
    jq 'del(.env.GH_TOKEN)' "$CLAUDE_SETTINGS_FILE" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# set_app_token_for_repo — Set GH_TOKEN for the owner of the given repo.
# Args: "owner/repo"
# No-op if the app isn't configured or doesn't have an installation for
# this owner (falls back to gh CLI auth).
# ---------------------------------------------------------------------------
set_app_token_for_repo() {
    local repo="$1"

    if [[ "$_APP_CONFIGURED" != "true" ]]; then
        return 0
    fi

    local owner
    owner=$(echo "$repo" | cut -d'/' -f1)

    # Look up installation for this owner (safe under set -u)
    local installation_id=""
    local _key
    for _key in "${!_APP_INSTALLATIONS[@]}"; do
        if [[ "$_key" == "$owner" ]]; then
            installation_id="${_APP_INSTALLATIONS[$_key]}"
            break
        fi
    done
    if [[ -z "$installation_id" ]]; then
        # No installation for this owner — fall back to gh CLI auth
        _clear_token_from_settings
        unset GH_TOKEN
        return 0
    fi

    # Check cache
    local cache_file="$TOKEN_CACHE_DIR/${installation_id}.json"
    if [[ -f "$cache_file" ]]; then
        local cached_token
        cached_token=$(jq -r '.token // empty' "$cache_file" 2>/dev/null)
        local cached_expires
        cached_expires=$(jq -r '.expires_at // empty' "$cache_file" 2>/dev/null)

        if [[ -n "$cached_token" && -n "$cached_expires" ]]; then
            local expires_epoch
            expires_epoch=$(date -d "$cached_expires" +%s 2>/dev/null) || expires_epoch=0
            local now
            now=$(date +%s)
            local remaining=$((expires_epoch - now))

            if [[ $remaining -gt 600 ]]; then
                export GH_TOKEN="$cached_token"
                _inject_token_into_settings "$cached_token"
                return 0
            fi
        fi
    fi

    # Generate fresh token
    local token
    token=$(_get_installation_token "$APP_ID" "$installation_id") || {
        # Remove stale token from settings.json so gh CLI auth can take over
        _clear_token_from_settings
        unset GH_TOKEN
        return 1
    }
    export GH_TOKEN="$token"
    _inject_token_into_settings "$token"
    return 0
}
