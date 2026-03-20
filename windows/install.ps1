#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install and configure claude-docker-worker for Windows (native, no Docker).

.DESCRIPTION
    Sets up the Windows-native worker that processes GitHub issues using Claude Code.
    Creates directory structure, validates prerequisites, copies config template,
    registers Task Scheduler jobs, and copies Claude Code settings.

.NOTES
    Run this script as Administrator from the claude-docker-worker\windows\ directory.
    Prerequisites: Git (with Git Bash), GitHub CLI, jq, Claude Code
#>

param(
    [string]$WorkerDir = "$env:LOCALAPPDATA\claude-docker-worker",
    [string]$GitBash = "C:\Program Files\Git\bin\bash.exe",
    [switch]$SkipScheduledTasks,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== Claude Docker Worker — Windows Setup ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Validate prerequisites
# ---------------------------------------------------------------------------
Write-Host "Checking prerequisites..." -ForegroundColor Yellow

$prereqs = @(
    @{ Name = "Git (with Git Bash)"; Test = { Test-Path $GitBash }; Fix = "Install Git for Windows: https://gitforwindows.org/" }
    @{ Name = "GitHub CLI (gh)";     Test = { Get-Command gh -ErrorAction SilentlyContinue }; Fix = "winget install GitHub.cli" }
    @{ Name = "jq";                  Test = { Get-Command jq -ErrorAction SilentlyContinue }; Fix = "winget install jqlang.jq" }
    @{ Name = "Claude Code";         Test = { Get-Command claude -ErrorAction SilentlyContinue }; Fix = "See https://claude.ai for installation" }
)

$missing = @()
foreach ($p in $prereqs) {
    if (& $p.Test) {
        Write-Host "  [OK] $($p.Name)" -ForegroundColor Green
    } else {
        Write-Host "  [MISSING] $($p.Name) — $($p.Fix)" -ForegroundColor Red
        $missing += $p.Name
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing prerequisites: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Install them and re-run this script."
    exit 1
}

# Check authentication status
Write-Host ""
Write-Host "Checking authentication..." -ForegroundColor Yellow

$ghAuth = gh auth status 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] GitHub CLI authenticated" -ForegroundColor Green
} else {
    Write-Host "  [WARN] GitHub CLI not authenticated — run 'gh auth login' after setup" -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# 2. Create directory structure
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Creating directory structure at $WorkerDir ..." -ForegroundColor Yellow

$dirs = @("state", "logs", "locks", "workdir", "scripts")
foreach ($d in $dirs) {
    $path = Join-Path $WorkerDir $d
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "  Created $d/" -ForegroundColor Green
    } else {
        Write-Host "  Exists  $d/" -ForegroundColor DarkGray
    }
}

# Initialize state files
$stateFiles = @("processed-issues.json", "seen-comments.json", "handled-mentions.json")
foreach ($f in $stateFiles) {
    $path = Join-Path $WorkerDir "state\$f"
    if (-not (Test-Path $path)) {
        Set-Content -Path $path -Value "{}"
        Write-Host "  Initialized state/$f" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 3. Copy scripts
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Copying scripts..." -ForegroundColor Yellow

$scriptsSrc = Join-Path $ScriptRoot "scripts"
$scriptsDst = Join-Path $WorkerDir "scripts"

Get-ChildItem -Path $scriptsSrc -Filter "*.sh" | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $scriptsDst -Force
    Write-Host "  Copied $($_.Name)" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 4. Copy config template
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Setting up configuration..." -ForegroundColor Yellow

$configDst = Join-Path $WorkerDir "config.yaml"
$configSrc = Join-Path $ScriptRoot "..\config.yaml.example"

if (-not (Test-Path $configDst) -or $Force) {
    Copy-Item -Path $configSrc -Destination $configDst
    Write-Host "  Copied config.yaml.example -> config.yaml" -ForegroundColor Green
    Write-Host "  IMPORTANT: Edit $configDst with your repos and settings" -ForegroundColor Yellow
} else {
    Write-Host "  config.yaml already exists (use -Force to overwrite)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 5. Copy Claude Code settings
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Setting up Claude Code settings..." -ForegroundColor Yellow

$claudeDir = Join-Path $env:USERPROFILE ".claude"
$settingsDst = Join-Path $claudeDir "settings.json"
$settingsSrc = Join-Path $ScriptRoot "..\settings.json.example"

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

if (-not (Test-Path $settingsDst) -or $Force) {
    Copy-Item -Path $settingsSrc -Destination $settingsDst
    Write-Host "  Copied settings.json.example -> ~/.claude/settings.json" -ForegroundColor Green
} else {
    Write-Host "  settings.json already exists (use -Force to overwrite)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 6. Register Task Scheduler jobs
# ---------------------------------------------------------------------------
if (-not $SkipScheduledTasks) {
    Write-Host ""
    Write-Host "Registering Task Scheduler jobs..." -ForegroundColor Yellow

    $scriptsPath = ($scriptsDst -replace '\\', '/') -replace '^([A-Z]):', '/$1'
    $scriptsPath = $scriptsPath.ToLower().Substring(0, 1) + $scriptsPath.Substring(1)
    # Convert to Git Bash format: C:\foo -> /c/foo
    $scriptsPathBash = ($scriptsDst -replace '\\', '/')
    $scriptsPathBash = $scriptsPathBash -replace '^([A-Za-z]):', { "/$($_.Groups[1].Value.ToLower())" }

    $tasks = @(
        @{
            Name        = "Claude-CommentMonitor"
            Description = "Claude Docker Worker: scans for @dockworker mentions every 5 minutes"
            Script      = "comment-monitor.sh"
            IntervalMin = 5
        }
        @{
            Name        = "Claude-IssueWorker"
            Description = "Claude Docker Worker: processes labeled issues every 30 minutes"
            Script      = "issue-worker.sh"
            IntervalMin = 30
        }
        @{
            Name        = "Claude-TokenKeepAlive"
            Description = "Claude Docker Worker: keeps Claude Code auth token alive"
            Script      = $null  # Special case — runs claude directly
            IntervalMin = 360    # Every 6 hours
        }
    )

    foreach ($task in $tasks) {
        # Remove existing task if present
        $existing = Get-ScheduledTask -TaskName $task.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $task.Name -Confirm:$false
            Write-Host "  Removed existing task: $($task.Name)" -ForegroundColor DarkGray
        }

        if ($task.Script) {
            $action = New-ScheduledTaskAction `
                -Execute $GitBash `
                -Argument "-l -c '$scriptsPathBash/$($task.Script)'" `
                -WorkingDirectory $WorkerDir
        } else {
            # Token keep-alive — just run claude ping
            $action = New-ScheduledTaskAction `
                -Execute "claude" `
                -Argument '--model opus -p "ping"'
        }

        $trigger = New-ScheduledTaskTrigger `
            -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes $task.IntervalMin)

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)

        Register-ScheduledTask `
            -TaskName $task.Name `
            -Description $task.Description `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -User $env:USERNAME `
            -RunLevel Highest | Out-Null

        Write-Host "  Registered: $($task.Name) (every $($task.IntervalMin) min)" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "Skipping Task Scheduler setup (-SkipScheduledTasks)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Edit your config:    notepad $configDst"
Write-Host "  2. Authenticate gh:     gh auth login  (if not already)"
Write-Host "  3. Authenticate Claude: claude auth login --headless"
Write-Host ""
Write-Host "Manual test:" -ForegroundColor Yellow
Write-Host "  & '$GitBash' -l -c '$scriptsPathBash/comment-monitor.sh'"
Write-Host "  & '$GitBash' -l -c '$scriptsPathBash/issue-worker.sh'"
Write-Host ""
Write-Host "Logs:" -ForegroundColor Yellow
Write-Host "  $WorkerDir\logs\"
Write-Host ""
Write-Host "To uninstall, run:" -ForegroundColor Yellow
Write-Host "  .\uninstall.ps1"
Write-Host ""
