#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up the Windows host for the windows-exec feature.

.DESCRIPTION
    Automates the full host-side setup: enables OpenSSH Server, configures
    sshd for admin key auth, generates (or accepts) an SSH key pair,
    authorizes it, and copies the private key into the container.

.PARAMETER KeyPath
    Path to an existing SSH private key. If omitted, a new ed25519 key pair
    is generated at ~/.ssh/docker_to_host_ed25519.

.PARAMETER ContainerName
    Name of the Docker container. Defaults to "claude-docker-worker".

.EXAMPLE
    .\setup-host.ps1
    .\setup-host.ps1 -KeyPath "$env:USERPROFILE\.ssh\mykey"
#>
param(
    [string]$KeyPath,
    [string]$ContainerName = "claude-docker-worker"
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 1. Enable and start OpenSSH Server
# ---------------------------------------------------------------------------

Write-Host "`n[1/6] Checking OpenSSH Server..." -ForegroundColor Cyan

$sshd = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    Write-Host "  Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    $sshd = Get-Service sshd
}

if ($sshd.Status -ne "Running") {
    Write-Host "  Starting sshd..."
    Start-Service sshd
}
Set-Service -Name sshd -StartupType Automatic
Write-Host "  OpenSSH Server is running." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Configure sshd for administrator key auth
# ---------------------------------------------------------------------------

Write-Host "`n[2/6] Configuring sshd..." -ForegroundColor Cyan

$sshdConfig = "C:\ProgramData\ssh\sshd_config"
$configContent = Get-Content $sshdConfig -Raw

# Ensure PubkeyAuthentication is enabled
if ($configContent -notmatch "(?m)^PubkeyAuthentication\s+yes") {
    if ($configContent -match "(?m)^#?\s*PubkeyAuthentication") {
        $configContent = $configContent -replace "(?m)^#?\s*PubkeyAuthentication.*", "PubkeyAuthentication yes"
    } else {
        $configContent += "`nPubkeyAuthentication yes"
    }
    Write-Host "  Enabled PubkeyAuthentication."
}

# Ensure Match Group administrators block exists with correct path
$matchBlock = "Match Group administrators`r`n  AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys"
if ($configContent -notmatch "(?m)^Match Group administrators") {
    $configContent += "`n$matchBlock"
    Write-Host "  Added Match Group administrators block."
} elseif ($configContent -match "__PROGRAMDATA__") {
    $configContent = $configContent -replace "__PROGRAMDATA__/ssh/administrators_authorized_keys", "C:/ProgramData/ssh/administrators_authorized_keys"
    Write-Host "  Fixed AuthorizedKeysFile path."
}

Set-Content -Path $sshdConfig -Value $configContent -Encoding ASCII -NoNewline
Write-Host "  sshd_config is ready." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. SSH key pair
# ---------------------------------------------------------------------------

Write-Host "`n[3/6] Setting up SSH key..." -ForegroundColor Cyan

if ($KeyPath) {
    # User provided an existing key
    if (-not (Test-Path $KeyPath)) {
        Write-Error "Key not found: $KeyPath"
    }
    $PrivateKey = $KeyPath
    $PublicKey = "$KeyPath.pub"
    if (-not (Test-Path $PublicKey)) {
        Write-Error "Public key not found: $PublicKey"
    }
    Write-Host "  Using existing key: $KeyPath"
} else {
    # Generate a new key pair
    $PrivateKey = "$env:USERPROFILE\.ssh\docker_to_host_ed25519"
    $PublicKey = "$PrivateKey.pub"
    if (Test-Path $PrivateKey) {
        Write-Host "  Key already exists at $PrivateKey — reusing it."
    } else {
        Write-Host "  Generating new ed25519 key pair..."
        ssh-keygen -t ed25519 -f $PrivateKey -N '""' -q
    }
}

Write-Host "  Key ready." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Authorize the key
# ---------------------------------------------------------------------------

Write-Host "`n[4/6] Authorizing key on host..." -ForegroundColor Cyan

$authKeysFile = "C:\ProgramData\ssh\administrators_authorized_keys"
$pubKeyContent = Get-Content $PublicKey -Raw

# Check if already authorized
$needsAuth = $true
if (Test-Path $authKeysFile) {
    $existing = Get-Content $authKeysFile -Raw -ErrorAction SilentlyContinue
    if ($existing -and $existing.Contains($pubKeyContent.Trim())) {
        Write-Host "  Key is already authorized."
        $needsAuth = $false
    }
}

if ($needsAuth) {
    Add-Content -Path $authKeysFile -Value $pubKeyContent.Trim() -Encoding ASCII
    Write-Host "  Key added to administrators_authorized_keys."
}

# Fix permissions — SYSTEM and Administrators only
icacls $authKeysFile /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
Write-Host "  Permissions set." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Restart sshd to pick up changes
# ---------------------------------------------------------------------------

Write-Host "`n[5/6] Restarting sshd..." -ForegroundColor Cyan
Restart-Service sshd
Write-Host "  sshd restarted." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Copy private key into the container
# ---------------------------------------------------------------------------

Write-Host "`n[6/6] Copying key into container..." -ForegroundColor Cyan

$containerRunning = docker ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($containerRunning -ne $ContainerName) {
    Write-Warning "Container '$ContainerName' is not running. Start it first, then run:"
    Write-Host "  docker cp `"$PrivateKey`" ${ContainerName}:/root/.ssh/windows_host_ed25519"
    Write-Host "  ssh claude-docker-worker `"chmod 600 /root/.ssh/windows_host_ed25519`""
} else {
    docker cp $PrivateKey "${ContainerName}:/root/.ssh/windows_host_ed25519"
    # chmod via docker exec since ssh may not be configured yet
    docker exec $ContainerName chmod 600 /root/.ssh/windows_host_ed25519
    Write-Host "  Key copied and permissions set." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 7. Detect username and update config
# ---------------------------------------------------------------------------

Write-Host "`n[Bonus] Detecting Windows username..." -ForegroundColor Cyan

$winUser = $env:USERNAME
$configFile = Join-Path $PSScriptRoot "config.snippet.yaml"

if (Test-Path $configFile) {
    $yaml = Get-Content $configFile -Raw
    if ($yaml -match '(?m)^\s*user:\s*""') {
        $yaml = $yaml -replace '(?m)^(\s*user:\s*)""', "`$1`"$winUser`""
        Set-Content -Path $configFile -Value $yaml -NoNewline
        Write-Host "  Set user to `"$winUser`" in config.snippet.yaml." -ForegroundColor Green
        Write-Host "  NOTE: Run 'bash build/assemble.sh' and rebuild to pick up this change." -ForegroundColor Yellow
    } else {
        Write-Host "  User already configured in config.snippet.yaml."
    }
} else {
    Write-Host "  config.snippet.yaml not found — configure the username manually."
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Host "`n Setup complete!" -ForegroundColor Green
Write-Host "Test with: ssh claude-docker-worker `"/opt/windows-exec/host-exec.sh whoami`""
Write-Host ""
