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

# Configure git to use gh CLI for HTTPS authentication
if command -v gh &> /dev/null && gh auth status &> /dev/null; then
    gh auth setup-git 2>/dev/null
fi

# Run feature entrypoint hooks (numbered for ordering)
if [ -d /opt/entrypoint.d ]; then
    for hook in /opt/entrypoint.d/*.sh; do
        [ -f "$hook" ] && [ -x "$hook" ] && "$hook"
    done
fi

# Start cron daemon in the background
cron

# Start sshd in the foreground (keeps the container alive)
exec /usr/sbin/sshd -D
