# Claude Docker Worker — Windows Native

Run the Claude Docker Worker directly on Windows without Docker. Uses Git Bash for script execution and Windows Task Scheduler instead of cron.

## Why Windows Native?

The standard worker runs in an Ubuntu Docker container. This Windows port enables:

- **AutoMap CLI access** — WebWorks AutoMap is Windows-only. The worker can now process documentation build tasks.
- **.NET development** — Direct access to .NET SDK, MSBuild, and Windows-native tooling.
- **Simpler setup** — No Docker layer, volumes, or container networking.

## Prerequisites

- [Git for Windows](https://gitforwindows.org/) (includes Git Bash)
- [GitHub CLI](https://cli.github.com/) — `winget install GitHub.cli`
- [jq](https://jqlang.github.io/jq/) — `winget install jqlang.jq`
- [Claude Code](https://claude.ai) — Claude Max or Team plan

## Setup

Run as Administrator:

```powershell
cd claude-docker-worker\windows
.\install.ps1
```

Then configure:

```powershell
notepad $env:LOCALAPPDATA\claude-docker-worker\config.yaml
```

```yaml
repos:
  - owner/repo-name

authorized_users:
  - your-github-username

label: claude-task
mention: "@dockworker"
bot_signature: "— 🚢 Claude Dockworker"
git_bot_name: "claude-docker-worker"
git_bot_email: "claude-docker-worker@noreply.github.com"
```

Authenticate:

```bash
gh auth login
claude auth login --headless
```

## How It Works

Three Task Scheduler jobs replace the Docker container's cron:

| Job | Interval | Purpose |
|-----|----------|---------|
| Claude-CommentMonitor | Every 5 minutes | Responds to `@dockworker` mentions |
| Claude-IssueWorker | Every 30 minutes | Picks up labeled issues, implements changes, opens PRs |
| Claude-TokenKeepAlive | Every 6 hours | Prevents OAuth token expiry |

Scripts run in Git Bash. State is stored in `%LOCALAPPDATA%\claude-docker-worker\`.

## AutoMap Integration

Issues are automatically detected as AutoMap tasks when they:

- Have a label containing "automap"
- Reference `.waj`, `.wep`, `.wrp`, or `.wxsp` files in the body
- Mention "automap" in the title

When detected, the worker runs AutoMap CLI before invoking Claude Code, so Claude can review and refine the build output.

## Manual Testing

Run scripts directly in Git Bash:

```bash
# Test comment monitoring
/c/Users/$USER/AppData/Local/claude-docker-worker/scripts/comment-monitor.sh

# Test issue processing
/c/Users/$USER/AppData/Local/claude-docker-worker/scripts/issue-worker.sh
```

## Logs

```
%LOCALAPPDATA%\claude-docker-worker\logs\comment-monitor-YYYY-MM-DD.log
%LOCALAPPDATA%\claude-docker-worker\logs\issue-worker-YYYY-MM-DD.log
```

## Uninstall

```powershell
cd claude-docker-worker\windows
.\uninstall.ps1              # Remove scheduled tasks only
.\uninstall.ps1 -RemoveState # Also remove state and logs
.\uninstall.ps1 -RemoveAll   # Remove everything
```

## Differences from Linux Version

| Feature | Linux (Docker) | Windows (Native) |
|---------|---------------|-----------------|
| Scheduler | cron | Task Scheduler |
| Shell | bash | Git Bash |
| Isolation | Container + iptables firewall | Host-level (no sandbox) |
| File locking | flock | mkdir-based (atomic on NTFS) |
| Paths | `/opt/issue-worker/`, `/root/` | `%LOCALAPPDATA%\claude-docker-worker\` |
| AutoMap CLI | Not available | Direct access |
| Remote access | SSH into container | Windows OpenSSH (optional) |
