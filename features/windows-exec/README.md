# Windows Host Execution

Execute commands and programs on the Windows host machine from inside the container via SSH.

## What It Does

Provides a bridge between the Linux container and the Windows host. When Claude encounters a task that requires Windows-native tools (MSBuild, .NET SDK, Visual Studio CLI, etc.), it can execute them on the host using the `host-exec.sh` wrapper.

The feature also injects a CLAUDE.md snippet so that Claude — in any context including automated workers — knows this capability exists and when to use it.

## Usage

```bash
# PowerShell (default)
/opt/windows-exec/host-exec.sh dotnet build MyProject.sln

# cmd.exe
/opt/windows-exec/host-exec.sh --cmd msbuild /t:Build

# With a working directory
/opt/windows-exec/host-exec.sh --cwd "C:\Projects\MyApp" cargo build
```

## Configuration

Edit `features/windows-exec/config.snippet.yaml`:

| Key | Description | Default |
|---|---|---|
| `hostname` | Host address | `host.docker.internal` |
| `port` | SSH port | `22` |
| `user` | Windows username | *(required)* |
| `identity_file` | Path to SSH private key inside container | `/root/.ssh/windows_host_ed25519` |

## Setup

Run the automated setup script from an **admin PowerShell**:

```powershell
.\features\windows-exec\setup-host.ps1                              # generate a new key
.\features\windows-exec\setup-host.ps1 -KeyPath ~/.ssh/mykey        # use an existing key
```

This enables OpenSSH Server, configures sshd, handles key auth (with correct
encoding and permissions), copies the key into the container, and detects your
Windows username for the config.

Prerequisites:
- **Docker Desktop** for Windows (provides `host.docker.internal` DNS resolution)
- An **admin PowerShell** to run the setup script

See `setup.md` for manual steps if preferred.
