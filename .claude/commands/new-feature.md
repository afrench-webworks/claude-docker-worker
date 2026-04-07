Create a new feature for the Claude Docker Worker. Walk through the steps below
interactively, gathering input from the user and scaffolding the feature directory.

## 1. Gather Feature Details

Ask the user:

- **Feature name** (kebab-case, used as the directory name — e.g., `flutter-dev`, `angular-cli`, `rust-toolchain`)
- **Display name** (human-readable — e.g., "Flutter Development Environment")
- **Description** (one sentence explaining what the feature adds)
- **Does it depend on other features?** (list feature names, or none)

## 2. Scaffold the Feature Directory

Create `features/<name>/` with the following files. Every file below is optional
except `feature.yaml` — only create the ones the user needs. Ask which apply.

### feature.yaml (always created)

```yaml
name: <name>
display_name: "<display_name>"
description: "<description>"
depends_on: []
install_dir: /opt/<name>
```

### Dockerfile.snippet

Ask: "Does this feature need system packages, SDKs, or tools installed in the
container?" If yes, help the user write the Dockerfile fragment.

Common patterns from existing features:

- **Apt packages**: `RUN apt-get update && apt-get install -y <packages> && rm -rf /var/lib/apt/lists/*`
- **Pip packages**: `RUN pip3 install --break-system-packages <packages>`
- **External installers**: `RUN curl -fsSL <url> | bash`
- **Copying scripts**: `COPY features/<name>/scripts/ /opt/<name>/` followed by `RUN chmod +x /opt/<name>/*.sh`

If the feature adds a Python module, set PYTHONPATH:
```dockerfile
ENV PYTHONPATH="/opt/<name>:${PYTHONPATH:-}"
```

### settings.snippet.json

Ask: "Does this feature need Claude Code to run any new commands?" If yes,
create a snippet adding those permissions. Follow the pattern:

```json
{
  "permissions": {
    "allow": [
      "Bash(flutter *)",
      "Bash(dart *)"
    ],
    "deny": []
  }
}
```

Only include permissions this feature specifically needs — base permissions
(git, file operations, etc.) are already in `core/settings.json.base`.

### config.snippet.yaml.example

Ask: "Does this feature have user-configurable settings?" If yes, create the
example config file with sensible defaults and comments explaining each option.
This file is committed to the repo. Users will get a copy at
`config.snippet.yaml` (gitignored) when they run `assemble.sh`.

### crontab.snippet

Ask: "Does this feature need scheduled tasks?" If yes, write cron entries.
Use `bash -l` to ensure PATH includes Claude Code:

```
*/10 * * * * /bin/bash -l -c '/opt/<name>/some-script.sh' >> /root/workspace/.<name>/logs/cron.log 2>&1
```

### entrypoint.d/<NN>-<name>.sh

Ask: "Does this feature need initialization at container boot?" If yes, create
a boot script. Use a number prefix for ordering (10 = early init, 20 = config,
30 = services). Common tasks:

- Create state/log directories on the persistent volume
- Initialize state files
- Clean up stale locks from previous runs
- Validate configuration

Pattern from existing features:

```bash
#!/bin/bash
set -e

STATE_BASE="/root/workspace/.<name>"

mkdir -p "$STATE_BASE/state"
mkdir -p "$STATE_BASE/logs"
mkdir -p "$STATE_BASE/locks"
mkdir -p "$STATE_BASE/workdir"
```

### setup.md

Ask: "Does this feature require manual setup steps beyond config?" If yes,
write feature-specific setup instructions. These are included by the master
`/setup` command when this feature is enabled. Use step prefixes to avoid
conflicts (e.g., `FL-1`, `FL-2` for a Flutter feature).

Common setup steps:
- Downloading credentials or keys
- Authenticating external services
- Running one-time initialization commands inside the container

### scripts/

Ask: "Does this feature include scripts that run inside the container?" If yes,
create the scripts directory and help write the scripts. Scripts are copied to
`/opt/<name>/` in the container via the Dockerfile snippet.

## 3. Enable the Feature

Add the feature name to `features.conf` (uncommented).

## 4. Test Assembly

Run `bash build/assemble.sh` and verify:
- No errors
- The generated Dockerfile includes the feature's snippet
- The generated settings.json includes the feature's permissions
- The generated crontab includes the feature's cron entries (if any)
- The generated config.yaml includes the feature's config (if any)
- The entrypoint hook was collected (if any)

Report the results and suggest next steps:
- Edit `features/<name>/config.snippet.yaml` with real values (if config exists)
- Run `bash build.sh` to build the image
- Run `bash run.sh` to start the container
