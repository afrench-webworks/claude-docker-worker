# Claude Docker Worker

<p align="center">
  <img src="claude-dockworker.png" alt="Claude Dockworker" width="400">
</p>

An always-on Docker container that autonomously works GitHub Issues using Claude Code (Opus). It responds to `@dockworker` mentions with repo-aware analysis, implements changes, opens pull requests, and addresses review feedback — all without human intervention.

## How It Works

Two cron-driven scripts run inside an Ubuntu 24.04 container:

- **Comment Monitor** (`comment-monitor.sh`) — Runs every 5 minutes, 24/7. Scans for `@dockworker` mentions across issue comments, PR conversations, inline code reviews, and review summaries. Responds with analysis grounded in the actual codebase. On PRs with a `claude/*` branch, it can make code changes and push commits in response to feedback. Processes one mention per cycle.

- **Issue Worker** (`issue-worker.sh`) — Runs every 30 minutes from midnight to 8 AM (configurable timezone). Picks up new issues with the trigger label, creates a branch, invokes Claude Code to implement changes, and opens a PR. Processes one issue per cycle.

Both scripts are silent when there's nothing to do and use file-based locking to prevent collisions. State is tracked in JSON files on a persistent volume.

## Quick Setup

If you have [Claude Code](https://claude.ai) installed, clone this repo and run:

```
claude
/setup
```

The slash command walks through the entire setup interactively.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- An SSH keypair on the host machine
- A [Claude](https://claude.ai) account (Max or Team plan) for Claude Code authentication
- A [GitHub](https://github.com) account with access to the repos you want to monitor

## Project Structure

```
claude-docker-worker/
├── .claude/commands/
│   └── setup.md            # Interactive setup slash command for Claude Code
├── .gitattributes           # Enforces LF line endings for shell scripts
├── .gitignore               # Excludes config.yaml and private keys
├── Dockerfile               # Ubuntu 24.04 + Claude Code + gh CLI + cron + SSH
├── README.md
├── config.yaml.example      # Template — copy to config.yaml and customize
├── crontab                  # Cron schedule for scripts + token keep-alive
├── docker-compose.yml       # Container config with named volumes
├── entrypoint.sh            # Boot-time setup (SSH keys, git auth, lock cleanup, cron)
├── settings.json.example    # Claude Code permissions — copied into container during setup
└── scripts/
    ├── common.sh            # Shared utilities (config, state, locking, logging)
    ├── comment-monitor.sh   # Mention-driven response loop
    ├── github-app-token.sh  # GitHub App JWT auth with auto-discovery
    └── issue-worker.sh      # Issue implementation and PR creation loop
```

## Manual Setup

If not using the `/setup` slash command:

### 1. Configure

Copy the example config and edit it:

```bash
cp config.yaml.example config.yaml
```

```yaml
repos:
  - owner/repo-name
  - org/another-repo

label: claude-task
mention: "@dockworker"
bot_signature: "— 🚢 Claude Dockworker"
git_bot_name: "claude-docker-worker"
git_bot_email: "claude-docker-worker@noreply.github.com"
```

### 2. Build

```bash
docker compose build
```

### 3. First Boot

Inject your SSH public key so you can SSH into the container:

**PowerShell:**
```powershell
$env:SSH_AUTHORIZED_KEY = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub"
docker compose up -d
$env:SSH_AUTHORIZED_KEY = ""
```

**Bash:**
```bash
SSH_AUTHORIZED_KEY="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d
```

Replace the key path with your actual public key file. The key is written to a persistent volume — subsequent starts don't need it.

### 4. Add SSH Config Entry

Add this to your `~/.ssh/config`:

```
Host claude-docker-worker
    HostName 127.0.0.1
    Port 41922
    User root
    IdentityFile ~/.ssh/id_ed25519
```

Adjust the port and key path to match your setup.

### 5. Install Claude Code Permissions

```bash
docker cp settings.json.example claude-docker-worker:/root/.claude/settings.json
```

This configures which tools Claude Code can use in non-interactive mode. Claude handles its own GitHub commenting via `gh`, so `Bash(gh *)` is in the allow list.

### 6. Authenticate Claude Code

```bash
ssh claude-docker-worker
claude auth login --headless
```

Open the printed URL in your browser, complete OAuth, and paste the code back. The token is stored on a persistent volume and survives rebuilds.

### 7. Authenticate GitHub CLI

Still inside the container:

```bash
gh auth login
gh auth setup-git
```

## Usage

### Mentioning the Bot

Tag `@dockworker` in any comment on a monitored repo to get a response:

- **On an issue** — researches the codebase and responds with grounded analysis
- **On a PR conversation** — if the PR has a `claude/*` branch, can make code changes and push
- **On an inline code review** — addresses the specific review feedback with file-level context
- **On a review summary** — responds to "request changes" feedback

### Issue Worker

Create an issue with the trigger label (default: `claude-task`) on a monitored repo. The issue worker picks it up during the work window (midnight-8 AM by default), implements changes, and opens a PR.

### Manual Runs

SSH into the container and run either script directly:

```bash
ssh claude-docker-worker

# Test comment monitoring
/opt/issue-worker/comment-monitor.sh

# Test issue implementation
/opt/issue-worker/issue-worker.sh
```

### Check Logs

```bash
# Cron output
cat /root/workspace/.issue-worker/logs/cron.log

# Per-script daily logs
cat /root/workspace/.issue-worker/logs/comment-monitor-$(date +%Y-%m-%d).log
cat /root/workspace/.issue-worker/logs/issue-worker-$(date +%Y-%m-%d).log
```

Both scripts produce zero log output on quiet cycles. Logs are rotated on boot (older than 30 days are deleted).

### Check State

```bash
# Which issues have been processed
cat /root/workspace/.issue-worker/state/processed-issues.json

# Which mentions have been handled
cat /root/workspace/.issue-worker/state/handled-mentions.json
```

### Reprocess an Issue

Remove its entry from the state file:

```bash
jq 'del(.["owner/repo#42"])' /root/workspace/.issue-worker/state/processed-issues.json > /tmp/pi.json \
  && mv /tmp/pi.json /root/workspace/.issue-worker/state/processed-issues.json
```

### Rebuild After Config or Script Changes

```bash
docker compose down
docker compose build
docker compose up -d
```

No need to re-inject SSH keys or re-authenticate — all credentials live in named volumes.

## Volumes

| Volume | Mount Point | Purpose |
|---|---|---|
| `claude-config` | `/root/.claude` | Claude Code auth tokens, settings, permissions |
| `gh-config` | `/root/.config/gh` | GitHub CLI credentials |
| `ssh-host-keys` | `/etc/ssh` | SSH host keys (stable fingerprint across rebuilds) |
| `ssh-authorized-keys` | `/root/.ssh` | Authorized public keys for SSH access |
| `workspace` | `/root/workspace` | Worker state, logs, repo clones |

## Configuration Reference

### config.yaml

| Key | Description |
|---|---|
| `repos` | List of `owner/repo` strings to monitor |
| `authorized_users` | GitHub usernames allowed to trigger the bot via mentions |
| `label` | GitHub label that triggers the issue worker (e.g., `claude-task`) |
| `mention` | Handle that triggers the comment monitor (e.g., `@dockworker`) |
| `bot_signature` | Appended to every comment posted by the bot |
| `git_bot_name` | Git committer name for automated commits |
| `git_bot_email` | Git committer email for automated commits |
| `app_id` | *(Optional)* GitHub App ID — enables posting as a bot identity instead of your personal account. Installations are auto-discovered at runtime. |

### Cron Schedule

Edit `crontab` to change polling intervals or work windows. The container timezone is set to `America/Chicago` in the Dockerfile — adjust `ln -sf /usr/share/zoneinfo/...` for a different timezone.

A token keep-alive job runs every 6 hours to prevent OAuth token expiry.

### SSH Port

The container binds to `127.0.0.1:41922` by default (localhost only, not exposed to LAN). Change the port mapping in `docker-compose.yml` if needed.

## Troubleshooting

**Container keeps restarting:** Check `docker compose logs`. Most commonly caused by CRLF line endings in `entrypoint.sh` — the `.gitattributes` file prevents this when cloning via git.

**Claude Code can't use tools:** Verify `/root/.claude/settings.json` has the permissions allowlist. Claude Code in `-p` (print) mode blocks tool use by default.

**Duplicate comments:** Claude posts its own replies via `gh`. The automation scripts no longer post comments for the comment monitor — only Claude does. If you see duplicates, check that an older version of the scripts isn't running.

**Git push fails:** Run `gh auth setup-git` inside the container. The entrypoint runs this on boot, but it requires `gh auth login` to have been completed first.

**Stale locks blocking runs:** The entrypoint clears lock files on boot. If a script hangs mid-run, restart the container or manually delete files in `/root/workspace/.issue-worker/locks/`.

**Auth token expired:** The cron keep-alive job should prevent this, but if it happens, SSH in and run `claude auth login --headless` again.
