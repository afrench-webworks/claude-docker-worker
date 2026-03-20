#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstall claude-docker-worker Windows scheduled tasks and optionally remove state.

.PARAMETER RemoveState
    Also remove all state, logs, and cached repo clones from %LOCALAPPDATA%\claude-docker-worker.
    Config file is preserved unless -RemoveAll is specified.

.PARAMETER RemoveAll
    Remove everything including config.yaml and the worker directory.
#>

param(
    [string]$WorkerDir = "$env:LOCALAPPDATA\claude-docker-worker",
    [switch]$RemoveState,
    [switch]$RemoveAll
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Claude Docker Worker — Windows Uninstall ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Remove scheduled tasks
# ---------------------------------------------------------------------------
Write-Host "Removing scheduled tasks..." -ForegroundColor Yellow

$taskNames = @("Claude-CommentMonitor", "Claude-IssueWorker", "Claude-TokenKeepAlive")
foreach ($name in $taskNames) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "  Removed: $name" -ForegroundColor Green
    } else {
        Write-Host "  Not found: $name" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# 2. Remove state/logs (optional)
# ---------------------------------------------------------------------------
if ($RemoveState -or $RemoveAll) {
    Write-Host ""
    Write-Host "Removing state and logs..." -ForegroundColor Yellow

    $dirsToRemove = @("state", "logs", "locks", "workdir", "scripts")
    foreach ($d in $dirsToRemove) {
        $path = Join-Path $WorkerDir $d
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            Write-Host "  Removed: $d/" -ForegroundColor Green
        }
    }
}

if ($RemoveAll) {
    Write-Host ""
    Write-Host "Removing entire worker directory..." -ForegroundColor Yellow
    if (Test-Path $WorkerDir) {
        Remove-Item -Path $WorkerDir -Recurse -Force
        Write-Host "  Removed: $WorkerDir" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Uninstall Complete ===" -ForegroundColor Cyan
Write-Host ""

if (-not $RemoveState -and -not $RemoveAll) {
    Write-Host "Scheduled tasks removed. State and config preserved at:" -ForegroundColor Yellow
    Write-Host "  $WorkerDir"
    Write-Host ""
    Write-Host "To also remove state:  .\uninstall.ps1 -RemoveState"
    Write-Host "To remove everything:  .\uninstall.ps1 -RemoveAll"
}

Write-Host ""
