Create a new feature for the Claude Docker Worker. Have a conversation with the
user to understand what they want, then scaffold everything for them.

## 1. Understand What the User Wants

Ask the user to describe what they want this feature to do. Examples:

- "I want the container to be able to do Flutter development"
- "I need Rust with cargo and clippy"
- "I want a scheduled script that checks my deploy status"
- "I need the container to work with AWS CLI"

From their description, figure out:

- A good kebab-case name for the feature directory (e.g., `flutter-dev`, `rust-toolchain`, `aws-cli`)
- A human-readable display name
- A one-line description

Confirm these with the user before proceeding.

## 2. Research and Plan

Based on what the user described, determine what the feature needs. Research
installation methods (official docs, apt packages, curl installers, pip packages)
as needed. Consider:

- **What tools need to be installed?** System packages, SDKs, CLIs, language
  runtimes, pip/npm packages, or tools installed via curl/wget.

- **What commands should Claude Code be able to run?** Any CLI tools the feature
  installs need to be added to the permissions allowlist so Claude can use them.

- **Does it need runtime configuration?** Settings that vary per user/machine
  (API keys, project paths, account IDs, etc.) belong in a config file. Static
  tool installations typically don't need config.

- **Does it run on a schedule?** Automated workers, pollers, or periodic tasks
  need cron entries. Dev environment features typically don't.

- **Does it need boot-time setup?** Features that maintain state across restarts
  (logs, locks, state files) need an entrypoint hook to initialize directories.
  Simple tool installations typically don't.

- **Does it require manual setup steps?** Things like authenticating external
  services, copying credentials, or creating accounts need documented setup steps.

- **Does it need custom scripts?** Automation features need scripts that run
  inside the container. Dev environment features typically just install tools.

Present a short summary of what you'll create and why. Don't reference file
conventions — describe it in terms of what the feature will do.

## 3. Scaffold the Feature

Read the existing features in `features/` to match the conventions. Then create
the feature directory and all necessary files.

Reference for the file conventions (the user doesn't need to know these details):

### feature.yaml (always created)

```yaml
name: <name>
display_name: "<display_name>"
description: "<description>"
depends_on: []
install_dir: /opt/<name>
```

### Dockerfile.snippet (when tools need installing)

Common patterns:
- Apt packages: `RUN apt-get update && apt-get install -y <packages> && rm -rf /var/lib/apt/lists/*`
- Pip packages: `RUN pip3 install --break-system-packages <packages>`
- External installers: `RUN curl -fsSL <url> | bash`
- Copying scripts: `COPY features/<name>/scripts/ /opt/<name>/` then `RUN chmod +x /opt/<name>/*.sh`
- Python modules: `ENV PYTHONPATH="/opt/<name>:${PYTHONPATH:-}"`

### settings.snippet.json (when Claude needs to run new commands)

```json
{
  "permissions": {
    "allow": ["Bash(tool_name *)"],
    "deny": []
  }
}
```

Base permissions (git, file ops, etc.) are already in `core/settings.json.base`.

### config.snippet.yaml.example (when there are user-configurable settings)

Committed to the repo. Users get a working copy at `config.snippet.yaml`
(gitignored) when they run `assemble.sh`.

### crontab.snippet (when there are scheduled tasks)

Use `bash -l` to ensure PATH includes Claude Code:
```
*/10 * * * * /bin/bash -l -c '/opt/<name>/some-script.sh' >> /root/workspace/.<name>/logs/cron.log 2>&1
```

### entrypoint.d/<NN>-<name>.sh (when boot-time init is needed)

Number prefix controls ordering (10 = early, 20 = config, 30 = services):
```bash
#!/bin/bash
set -e
STATE_BASE="/root/workspace/.<name>"
mkdir -p "$STATE_BASE/state" "$STATE_BASE/logs" "$STATE_BASE/locks" "$STATE_BASE/workdir"
```

### setup.md (when manual setup steps are needed)

Feature-specific setup instructions included by the master `/setup` command.
Use step prefixes to avoid conflicts (e.g., `FL-1`, `FL-2`).

### scripts/ (when custom scripts run inside the container)

Scripts are copied to `/opt/<name>/` via the Dockerfile snippet.

### README.md (always created)

A short readme explaining what the feature does, what tools are included,
and any configuration or setup needed.

## 4. Enable and Test

1. Add the feature name to `features.conf`
2. Run `bash build/assemble.sh`
3. Verify no errors and that the generated files include the new feature
4. Report results and suggest next steps (`bash build.sh` to build, `bash run.sh` to start)
