# Code Review Findings — feature/windows-native-worker

Date: 2026-03-20
Status: pending fixes

## P1 — Critical (Blocks Merge)

### P1-1: Command injection via AutoMap CLI `cmd.exe /c`
- **File:** `windows/scripts/issue-worker.sh:75`
- **Issue:** File path extracted from untrusted issue body via regex, passed directly to `cmd.exe /c`. `cmd.exe` honors `&`, `|`, `^` as command separators.
- **Fix:** Validate extracted file path with strict allowlist regex (alphanumeric, hyphens, underscores, dots, path separators only). Reject anything else. Avoid `cmd.exe /c` string interpolation — call AutoMap.exe directly if possible.

### P1-2: Token cache files stored without ACLs
- **File:** `windows/scripts/github-app-token.sh:112`
- **Issue:** `chmod 600` dropped from Linux version with no Windows equivalent. Token cache readable by all local users.
- **Fix:** Add `icacls` call after writing cache files, or set ACLs on the cache directory in `install.ps1` using `Set-Acl`.

### P1-3: Token leakage into logs and GitHub comments
- **Files:** `windows/scripts/github-app-token.sh:103`, `windows/scripts/issue-worker.sh:264-268`
- **Issue:** Raw API error responses logged. Full `$claude_output` posted to GitHub comments on failure.
- **Fix:** Log only error message (via `jq -r '.message'`), not full response. Truncate and filter `$claude_output` before posting to GitHub.

## P2 — Important (Should Fix)

### P2-1: Scheduled tasks run at `-RunLevel Highest`
- **File:** `windows/install.ps1:221`
- **Fix:** Change `-RunLevel Highest` to `-RunLevel Limited`.

### P2-2: Stale lock files survive crashes
- **File:** `windows/scripts/common.sh:114-154`
- **Fix:** Add stale-lock detection — read PID from lock dir, check if process alive via `kill -0`, reclaim if dead. Apply to both `acquire_lock` and `acquire_repo_lock`.

### P2-3: No log rotation
- **File:** `windows/scripts/common.sh:160-166`
- **Fix:** Add `find "$LOG_DIR" -name "*.log" -mtime +14 -delete 2>/dev/null` to `setup_logging()`.

### P2-4: Missing work window enforcement
- **File:** `windows/install.ps1` task registration
- **Fix:** Either add time boundaries to Task Scheduler trigger for issue-worker, or add a time-of-day check at the top of `issue-worker.sh`.

### P2-5: `git add -A` after AutoMap may commit sensitive files
- **File:** `windows/scripts/issue-worker.sh:215-218`
- **Fix:** Add `.gitignore` entries for sensitive patterns before staging, or use targeted `git add` of known output directories.

## P3 — Nice-to-Have (Post-Merge)

- P3-1: Remove dead variable `_HOME` from `common.sh:16`
- P3-2: Remove dead variable `$scriptsPath` from `install.ps1:156-157`
- P3-3: Remove dead function `write_state_scalar` from `common.sh:212-223`
- P3-4: Replace `grep -oP '\d+$'` with `grep -oE '[0-9]+$'` in `comment-monitor.sh:322`
- P3-5: Use `jq` instead of `printf` for token cache writes in `github-app-token.sh:112`
- P3-6: Use `jq` for fallback JSON construction in `issue-worker.sh:203`
- P3-7: Fix `cmd.exe` path quoting for paths with spaces in `issue-worker.sh:75`
- P3-8: Remove `--model opus` from token keep-alive ping in `install.ps1`
- P3-9: Extract `ensure_repo_clone()` into `common.sh` (both platforms)
- P3-10: Backport config improvements to Linux scripts
