# GitHub Issue/PR Worker

Autonomous GitHub issue triage, implementation, and `@mention` response powered by Claude Code.

## What It Does

A unified worker runs every 5 minutes via cron, scanning configured repos for actionable work:

### Mentions (priority 10, 24/7)

Tag `@dockworker` (configurable) in any comment on a monitored repo:

- **On an issue** — researches the codebase and responds with grounded analysis
- **On a PR conversation** — if the PR has a branch, can make code changes and push
- **On an inline code review** — addresses specific review feedback with file-level context
- **On a review summary** — responds to "request changes" feedback

### Issues (priority 20, configurable time window)

Create an issue on a monitored repo. The worker:

1. **Evaluates** it for AI readiness — labels it `dockworker:ready`, `dockworker:needs-info`, or `dockworker:skip`
2. **Implements** ready issues — creates a branch, invokes Claude Code, opens a PR
3. **Tracks lifecycle** — transitions `dockworker:pr-open` to `dockworker:done` when PRs are merged

Only one issue per repo is actively worked on at a time. Evaluation continues regardless.

## Configuration

Edit `features/github-worker/config.snippet.yaml`:

| Key | Description |
|---|---|
| `repos` | List of `owner/repo` strings to monitor |
| `authorized_users` | GitHub usernames allowed to trigger the bot via mentions |
| `mention` | Handle that triggers responses (default: `@dockworker`) |
| `bot_signature` | Appended to every comment posted by the bot |
| `git_bot_name` | Git committer name for automated commits |
| `git_bot_email` | Git committer email for automated commits |
| `label_prefix` | Prefix for workflow labels (default: `dockworker`) |
| `app_id` | GitHub App ID for bot identity (recommended) |
| `issue_work_window_start` | Hour (24h) when issue processing begins. Omit for 24/7. |
| `issue_work_window_end` | Hour (24h) when issue processing stops. Omit for 24/7. |
| `claude.issue_evaluation` | Model and effort for evaluating issues |
| `claude.issue_work` | Model and effort for implementing issues |
| `claude.mention_reply` | Model and effort for mention responses |

## Authentication

Two options:

### GitHub App (Recommended)

Posts comments under a bot identity. Create a GitHub App with Contents, Issues, and Pull Requests permissions, then set `app_id` in config and copy the private key into the container at `/root/.claude/github-app-key.pem`.

Installations are auto-discovered — install the app on your accounts/orgs and it finds them at runtime.

### Personal Account

Uses `gh auth login` credentials. Comments appear under your personal account. No `app_id` needed.

## Labels

The worker uses a label system (prefix configurable, default `dockworker`):

| Label | Meaning |
|---|---|
| `dockworker:ready` | Evaluated, ready for AI implementation |
| `dockworker:evaluating` | Currently being evaluated |
| `dockworker:needs-info` | Awaiting clarification from the issue author |
| `dockworker:in-progress` | Currently being worked on |
| `dockworker:pr-open` | Pull request created, awaiting review |
| `dockworker:done` | Completed successfully |
| `dockworker:failed` | Work attempt failed |
| `dockworker:skip` | Not suitable for AI work |

Labels are created automatically on first run. Remove a label to allow re-evaluation or re-processing.

## Manual Runs and Debugging

```bash
ssh claude-docker-worker

# Run the worker manually
/opt/github-worker/worker.sh

# Check logs
cat /root/workspace/.github-worker/logs/cron.log
cat /root/workspace/.github-worker/logs/worker-$(date +%Y-%m-%d).log

# Check state
cat /root/workspace/.github-worker/state/processed-issues.json
cat /root/workspace/.github-worker/state/handled-mentions.json

# Reprocess an issue
jq 'del(.["owner/repo#42"])' /root/workspace/.github-worker/state/processed-issues.json > /tmp/pi.json \
  && mv /tmp/pi.json /root/workspace/.github-worker/state/processed-issues.json
```

The worker produces zero log output on quiet cycles. Logs older than 30 days are rotated on boot.

## Scripts

```
scripts/
├── common.sh            # Config parsing, state, locking, WIP, logging
├── worker.sh            # Unified work loop (cron entry point)
├── dw_github/           # Python GitHub API module (PyGithub)
│   ├── auth.py          # GitHub App JWT + personal token auth
│   ├── client.py        # Authenticated client factory
│   ├── cli.py           # CLI entry points (called from bash handlers)
│   ├── config.py        # YAML config loader
│   ├── issues.py        # Issue scanning, evaluation, label management
│   ├── labels.py        # dockworker:* label system
│   ├── mentions.py      # Mention scanning across PRs and issues
│   └── pulls.py         # Pull request operations
├── handlers/
│   ├── mentions.sh      # Mention response (branch-edit or read-only mode)
│   └── issues.sh        # Issue evaluation + implementation
└── prompts/
    ├── respond-on-branch.md
    └── respond-readonly.md
```
