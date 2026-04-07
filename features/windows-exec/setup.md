## Windows Host Execution Setup

These steps configure SSH access from the container to your Windows host.

### Automated Setup (Recommended)

Run the setup script from an **elevated (admin) PowerShell**:

```powershell
.\features\windows-exec\setup-host.ps1
```

This handles everything: enables OpenSSH Server, configures sshd, generates a
key pair, authorizes it, copies it into the container, and detects your username.

To use an existing SSH key instead of generating a new one:

```powershell
.\features\windows-exec\setup-host.ps1 -KeyPath "$env:USERPROFILE\.ssh\mykey"
```

After running the script, rebuild if it updated your username in config:

```powershell
bash build/assemble.sh
docker compose build
docker compose up -d
```

Then test:

```powershell
ssh claude-docker-worker "/opt/windows-exec/host-exec.sh whoami"
```

---

### Manual Setup

If you prefer to set things up manually, follow these steps.

#### WE-1. Enable OpenSSH Server on Windows

Open **Settings > System > Optional Features > Add a feature**, search for
"OpenSSH Server", and install it. Then start the service:

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Verify it's running: `Get-Service sshd` should show "Running".

#### WE-2. Configure sshd for Administrator Key Auth

Edit `C:\ProgramData\ssh\sshd_config` in an admin editor. Ensure these lines
are present:

```
PubkeyAuthentication yes
```

And at the **end** of the file, add:

```
Match Group administrators
  AuthorizedKeysFile C:/ProgramData/ssh/administrators_authorized_keys
```

Use the full `C:/ProgramData/...` path — the `__PROGRAMDATA__` placeholder does
not always resolve correctly. Then restart sshd:

```powershell
Restart-Service sshd
```

#### WE-3. Configure the Feature

Edit `features/windows-exec/config.snippet.yaml` (created automatically from
the `.example` file by `assemble.sh` if it didn't exist).

Walk the user through filling in:

- **user**: Their Windows username (run `whoami` in PowerShell to find it — use
  just the username part after the backslash, e.g., `jsmith` not `DESKTOP\jsmith`)
- **hostname**: Usually `host.docker.internal` (the default) — only change if
  Docker Desktop isn't being used
- **port**: Usually `22` (the default)

Write their answers into `features/windows-exec/config.snippet.yaml`.

#### WE-4. Generate an SSH Key Pair

Generate a dedicated key pair for host access. Run on the host:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\docker_to_host_ed25519" -N ""
```

Or use an existing key — just note the path for the next steps.

#### WE-5. Authorize the Key on Windows

Add the public key to the Windows SSH authorized keys. For **administrators**,
use `-Encoding ASCII` — PowerShell's `>>` operator writes UTF-16 by default,
which OpenSSH cannot read:

```powershell
Get-Content "$env:USERPROFILE\.ssh\docker_to_host_ed25519.pub" | Add-Content -Encoding ASCII "C:\ProgramData\ssh\administrators_authorized_keys"
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)"
Restart-Service sshd
```

For **standard users**:
```powershell
Get-Content "$env:USERPROFILE\.ssh\docker_to_host_ed25519.pub" | Add-Content -Encoding ASCII "$env:USERPROFILE\.ssh\authorized_keys"
```

#### WE-6. Copy the Private Key into the Container

After the container is running, copy the private key in:

```powershell
docker cp "$env:USERPROFILE\.ssh\docker_to_host_ed25519" claude-docker-worker:/root/.ssh/windows_host_ed25519
ssh claude-docker-worker "chmod 600 /root/.ssh/windows_host_ed25519"
```

The key is stored on the `ssh-authorized-keys` volume at `/root/.ssh/` and
survives container rebuilds — you only need to copy it once.

#### WE-7. Test the Connection

```powershell
ssh claude-docker-worker "/opt/windows-exec/host-exec.sh whoami"
```

This should print your Windows username. If it fails, check that:
- OpenSSH Server is running on Windows (`Get-Service sshd`)
- The key is in the correct authorized_keys file with ASCII encoding
- The `Match Group administrators` block uses the full `C:/ProgramData/...` path
- Windows Firewall allows inbound TCP port 22
