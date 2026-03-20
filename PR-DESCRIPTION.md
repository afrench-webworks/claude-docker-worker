# feat: Add Windows-native worker for AutoMap CLI support

## Summary

- Adds a `windows/` directory with a complete Windows-native port of the issue worker and comment monitor, running in Git Bash via Windows Task Scheduler instead of cron in a Docker container.
- Primary motivation: enable the worker to invoke **WebWorks AutoMap CLI**, a Windows-only tool for building and publishing documentation, as part of the automated issue-to-PR pipeline.
- Secondary benefit: enables the worker to perform Windows .NET development tasks.
- The original Linux/Docker implementation is **completely untouched** — both deployment paths coexist in the same repo.

## Architecture Decision

Two approaches were evaluated (see [plan document](https://github.com/quadralay/webworks-brain/blob/main/docs/plans/2026-03-20-002-feat-claude-worker-windows-automap-plan.md)):

| Approach | Description | Verdict |
|----------|-------------|---------|
| **A: Native Windows Service** | Run scripts directly on Windows via Git Bash + Task Scheduler | **Selected** — simplest path to AutoMap, lowest maintenance |
| B: Hybrid (Linux + Windows sidecar) | Keep Linux container, add Windows bridge for AutoMap calls | Deferred — adds cross-system complexity for no incremental benefit on a personal dev machine |

## What Changed

### New files (`windows/`)

| File | Purpose |
|------|---------|
| `windows/scripts/common.sh` | Shared utilities ported for Windows: `cygpath` path translation, `mkdir`-based locking (replaces `flock`), state in `%LOCALAPPDATA%\claude-docker-worker\` |
| `windows/scripts/github-app-token.sh` | GitHub App JWT auth — paths updated to `$USERPROFILE/.claude/` |
| `windows/scripts/comment-monitor.sh` | Mention handler — functionally identical to Linux version, inherits Windows paths from common.sh |
| `windows/scripts/issue-worker.sh` | Issue processor — adds **AutoMap CLI detection and invocation** (detects by label, `.waj`/`.wep`/`.wrp`/`.wxsp` file references, or title keywords) |
| `windows/install.ps1` | PowerShell setup script: validates prerequisites, creates directory structure, copies scripts/config, registers 3 Task Scheduler jobs |
| `windows/uninstall.ps1` | Clean removal of scheduled tasks with optional state/config cleanup |
| `windows/README.md` | Windows-specific setup and usage documentation |

### Modified files

| File | Change |
|------|--------|
| `.gitattributes` | Added `windows/scripts/*.sh text eol=lf` to enforce LF line endings |

### Untouched files (original Linux/Docker path)

- `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `crontab`
- `scripts/common.sh`, `scripts/comment-monitor.sh`, `scripts/issue-worker.sh`, `scripts/github-app-token.sh`
- `config.yaml.example`, `settings.json.example`

## Key Porting Decisions

| Linux Feature | Windows Replacement | Rationale |
|---------------|-------------------|-----------|
| `flock` (file locking) | `mkdir`-based locking | `mkdir` is atomic on NTFS; `flock` unavailable in Git Bash |
| `/root/` paths | `$USERPROFILE` via `cygpath` | Standard Windows home directory |
| `/opt/issue-worker/` state | `$LOCALAPPDATA/claude-docker-worker/` | Windows convention for per-user app data |
| cron | Windows Task Scheduler | Three jobs: comment-monitor (5min), issue-worker (30min), token-keepalive (6hr) |
| `chmod 600` | Omitted | Windows ACLs are not chmod-compatible; install.ps1 runs as admin user |
| iptables firewall | Not implemented | Acceptable tradeoff for personal dev machine; noted in risk analysis |

## AutoMap Integration (New Feature)

The `issue-worker.sh` adds AutoMap detection and invocation:

```bash
detect_automap_task()  # Checks labels, file extensions, title keywords
run_automap_build()    # Extracts project file from issue body, runs AutoMap CLI via cmd.exe
```

**Workflow when AutoMap task is detected:**
1. Clone repo and create branch (same as standard flow)
2. Run AutoMap CLI on the referenced project file
3. Commit AutoMap build output
4. Invoke Claude Code with context about the AutoMap output
5. Claude reviews/refines, makes additional changes if needed
6. Push and open PR

## Known Limitations

- **No container isolation** — scripts run with host-level privileges. Mitigated by using Claude Code's `settings.json` allowlist instead of `--dangerously-skip-permissions`.
- **Script duplication** — `windows/scripts/` are forked copies of `scripts/`, not shared code. Changes to one must be manually replicated. Acceptable for now given the scripts are stable and AutoMap logic is Windows-only.
- **AutoMap CLI path** — `run_automap_build()` assumes `AutoMap.exe` is in PATH. May need adjustment for specific installation paths.
- **No `chmod 600`** — Token cache files in `github-app-token.sh` don't have restrictive permissions on Windows.

## Testing Performed

- All four `.sh` files pass `bash -n` syntax checking in Git Bash
- `cygpath` path translation verified: `$USERPROFILE` → `/c/Users/mcdow`, `$LOCALAPPDATA` → `/c/Users/mcdow/AppData/Local`
- `mkdir`-based locking verified: acquire and release works correctly on NTFS
- `date -Iseconds` produces valid ISO 8601 timestamps in Git Bash
- `jq`, `gh`, `openssl`, `claude` all resolve and execute in Git Bash
- Config parsing from `common.sh` correctly reads `config.yaml.example`
- `ensure_dirs` creates all required state directories

## Test Plan

- [ ] Run `install.ps1` as Administrator — verify directory creation, script copying, Task Scheduler registration
- [ ] Verify Task Scheduler jobs appear in Task Scheduler (taskschd.msc)
- [ ] Configure `config.yaml` with a test repo and run `comment-monitor.sh` manually — verify silent exit when no mentions
- [ ] Configure `config.yaml` with a test repo, create a labeled issue, run `issue-worker.sh` manually — verify it processes the issue and opens a PR
- [ ] Create an issue referencing a `.waj` file, run `issue-worker.sh` — verify AutoMap detection triggers
- [ ] Run `uninstall.ps1` — verify scheduled tasks are removed
- [ ] Run `uninstall.ps1 -RemoveAll` — verify full cleanup
