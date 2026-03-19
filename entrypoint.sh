#!/bin/bash
set -e

# Generate SSH host keys on first boot or after volume wipe
ssh-keygen -A

# Inject authorized public key from environment variable if provided.
# Used during first-time setup to avoid needing to exec into the container.
if [ -n "$SSH_AUTHORIZED_KEY" ]; then
    echo "$SSH_AUTHORIZED_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    unset SSH_AUTHORIZED_KEY
fi

# Ensure issue worker state directories exist on the persistent volume
mkdir -p /root/workspace/.issue-worker/state
mkdir -p /root/workspace/.issue-worker/logs
mkdir -p /root/workspace/.issue-worker/locks
mkdir -p /root/workspace/.issue-worker/workdir

# Initialize state files if they don't exist
[ -f /root/workspace/.issue-worker/state/processed-issues.json ] || echo '{}' > /root/workspace/.issue-worker/state/processed-issues.json
[ -f /root/workspace/.issue-worker/state/seen-comments.json ] || echo '{}' > /root/workspace/.issue-worker/state/seen-comments.json

# Clear stale lock files from previous runs/crashes
rm -f /root/workspace/.issue-worker/locks/*.lock

# Rotate logs — delete log files older than 30 days
find /root/workspace/.issue-worker/logs -name "*.log" -mtime +30 -delete 2>/dev/null || true

# Configure git to use gh CLI for HTTPS authentication
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    gh auth setup-git 2>/dev/null
fi

# Start cron daemon in the background
cron

# Start sshd in the foreground (keeps the container alive)
exec /usr/sbin/sshd -D
