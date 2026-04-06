FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base dependencies + SSH server + cron + jq
RUN apt-get update && apt-get install -y \
    openssh-server \
    cron \
    curl \
    git \
    jq \
    ca-certificates \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Python dependencies for the GitHub API module
RUN pip3 install --break-system-packages PyGithub PyJWT cryptography pyyaml

# Set timezone to America/Chicago (CST/CDT)
RUN ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime \
    && echo "America/Chicago" > /etc/timezone

# GitHub CLI — official apt source
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code — native installer (no Node.js dependency)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Ensure ~/.local/bin is on PATH for all session types
RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc \
    && echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.profile

# Claude Code permissions — base allowlist (auth module adds GH_TOKEN at runtime)
RUN mkdir -p /root/.claude
COPY settings.json.example /root/.claude/settings.json

# Issue worker scripts and config
COPY config.yaml /opt/issue-worker/config.yaml
COPY scripts/ /opt/issue-worker/
RUN chmod +x /opt/issue-worker/*.sh /opt/issue-worker/handlers/*.sh

# Python module path — allows `python3 -m dw_github.cli` from anywhere
ENV PYTHONPATH="/opt/issue-worker"
RUN echo 'export PYTHONPATH="/opt/issue-worker"' >> /root/.bashrc \
    && echo 'export PYTHONPATH="/opt/issue-worker"' >> /root/.profile \
    && echo 'PYTHONPATH=/opt/issue-worker' >> /etc/environment

# Cron schedule
COPY crontab /etc/cron.d/issue-worker
RUN chmod 0644 /etc/cron.d/issue-worker && crontab /etc/cron.d/issue-worker

# SSH hardening — key auth only, no passwords
RUN mkdir /var/run/sshd \
    && sed -i 's|#PermitRootLogin.*|PermitRootLogin yes|' /etc/ssh/sshd_config \
    && sed -i 's|#PubkeyAuthentication.*|PubkeyAuthentication yes|' /etc/ssh/sshd_config \
    && sed -i 's|#PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh

EXPOSE 22

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
