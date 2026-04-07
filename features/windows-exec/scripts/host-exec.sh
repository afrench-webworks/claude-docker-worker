#!/bin/bash
# host-exec.sh — Execute a command on the Windows host via SSH.
#
# Usage:
#   /opt/windows-exec/host-exec.sh <command> [args...]
#   /opt/windows-exec/host-exec.sh --powershell <command> [args...]
#   /opt/windows-exec/host-exec.sh --cmd <command> [args...]
#
# Options:
#   --powershell   Run the command through PowerShell (default)
#   --cmd          Run the command through cmd.exe
#   --cwd <path>   Set the working directory on the host before running
#
# Examples:
#   /opt/windows-exec/host-exec.sh dotnet build MyProject.sln
#   /opt/windows-exec/host-exec.sh --cmd msbuild /t:Build /p:Configuration=Release
#   /opt/windows-exec/host-exec.sh --cwd "C:\Projects\MyApp" cargo build
set -euo pipefail

CONFIG_FILE="/opt/dockworker/config.yaml"

# ---------------------------------------------------------------------------
# Parse config
# ---------------------------------------------------------------------------

get_config() {
    local key="$1"
    local default="${2:-}"
    local val
    val=$(grep "^[[:space:]]*${key}:" "$CONFIG_FILE" 2>/dev/null \
        | head -1 \
        | sed 's/^[^:]*:[[:space:]]*//' \
        | sed 's/^"//' | sed 's/"$//' \
        | sed "s/^'//" | sed "s/'$//")
    if [[ -n "$val" ]]; then
        echo "$val"
    else
        echo "$default"
    fi
}

HOST=$(get_config "hostname" "host.docker.internal")
PORT=$(get_config "port" "22")
USER=$(get_config "user" "")
IDENTITY=$(get_config "identity_file" "/root/.ssh/windows_host_ed25519")

if [[ -z "$USER" ]]; then
    echo "ERROR: windows_host.user is not configured in $CONFIG_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

SHELL_PREFIX="powershell.exe -NoProfile -NonInteractive -Command"
CWD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --powershell)
            SHELL_PREFIX="powershell.exe -NoProfile -NonInteractive -Command"
            shift
            ;;
        --cmd)
            SHELL_PREFIX="cmd.exe /C"
            shift
            ;;
        --cwd)
            CWD="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "Usage: host-exec.sh [--powershell|--cmd] [--cwd <path>] <command> [args...]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build and execute SSH command
# ---------------------------------------------------------------------------

SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
    -o BatchMode=yes
    -i "$IDENTITY"
    -p "$PORT"
)

REMOTE_CMD=""
if [[ -n "$CWD" ]]; then
    REMOTE_CMD="cd '$CWD' ; "
fi
REMOTE_CMD+="$SHELL_PREFIX $*"

exec ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" "$REMOTE_CMD"
