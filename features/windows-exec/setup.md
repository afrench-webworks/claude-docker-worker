## Windows Host Execution Setup

These steps configure SSH access from the container to your Windows host.

### WE-1. Enable OpenSSH Server on Windows

Tell the user to open **Settings > System > Optional Features > Add a feature**,
search for "OpenSSH Server", and install it. Then start the service:

```powershell
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Verify it's running: `Get-Service sshd` should show "Running".

### WE-2. Configure the Feature

Edit `features/windows-exec/config.snippet.yaml` (created automatically from
the `.example` file by `assemble.sh` if it didn't exist).

Walk the user through filling in:

- **user**: Their Windows username (run `whoami` in PowerShell to find it — use
  just the username part after the backslash, e.g., `jsmith` not `DESKTOP\jsmith`)
- **hostname**: Usually `host.docker.internal` (the default) — only change if
  Docker Desktop isn't being used
- **port**: Usually `22` (the default)

Write their answers into `features/windows-exec/config.snippet.yaml`.

### WE-3. Generate an SSH Key Pair

Generate a dedicated key pair for host access. Run on the host:

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\docker_to_host_ed25519" -N ""
```

### WE-4. Authorize the Key on Windows

Add the public key to the Windows SSH authorized keys. The location depends on
whether the user is a standard user or administrator.

For **standard users**:
```powershell
Get-Content "$env:USERPROFILE\.ssh\docker_to_host_ed25519.pub" >> "$env:USERPROFILE\.ssh\authorized_keys"
```

For **administrators** (Windows uses a separate file):
```powershell
Get-Content "$env:USERPROFILE\.ssh\docker_to_host_ed25519.pub" >> "C:\ProgramData\ssh\administrators_authorized_keys"
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)"
```

Ask which applies and guide them through the right one.

### WE-5. Copy the Private Key into the Container

After the container is running, copy the private key in:

```powershell
docker cp "$env:USERPROFILE\.ssh\docker_to_host_ed25519" claude-docker-worker:/root/.ssh/windows_host_ed25519
ssh claude-docker-worker "chmod 600 /root/.ssh/windows_host_ed25519"
```

### WE-6. Test the Connection

SSH into the container and test:

```bash
ssh claude-docker-worker
/opt/windows-exec/host-exec.sh whoami
```

This should print the Windows username. If it fails, check that:
- OpenSSH Server is running on Windows (`Get-Service sshd`)
- The key is in the correct authorized_keys file
- Windows Firewall allows inbound TCP port 22
