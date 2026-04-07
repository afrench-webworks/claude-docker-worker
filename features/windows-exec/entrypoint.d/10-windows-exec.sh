#!/bin/bash
# Boot-time initialization for the Windows host execution feature
set -e

STATE_BASE="/root/workspace/.windows-exec"

# Ensure state directories exist on the persistent volume
mkdir -p "$STATE_BASE/logs"

# Test host connectivity (non-blocking — log result but don't fail boot)
CONFIG_FILE="/opt/dockworker/config.yaml"
HOST=$(grep '^\s*hostname:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/^"//' | sed 's/"$//' || echo "host.docker.internal")
PORT=$(grep '^\s*port:' "$CONFIG_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | sed 's/^"//' | sed 's/"$//' || echo "22")

if timeout 5 bash -c "echo >/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    echo "[windows-exec] Host SSH reachable at $HOST:$PORT"
else
    echo "[windows-exec] WARNING: Cannot reach host SSH at $HOST:$PORT — check OpenSSH Server on Windows"
fi
