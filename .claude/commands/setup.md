Set up the Claude Docker Worker on this machine. Walk through each step below,
verifying prerequisites before proceeding and asking the user for input where noted.
Stop and report if any step fails.

## 1. Verify Prerequisites

Check that the following are available. If any are missing, stop and tell the user
what needs to be installed before continuing.

- Docker Desktop is installed and the engine is running (`docker info`)
- Docker Compose v2 is available (`docker compose version`)
- `jq` is installed (`jq --version`). If missing, help the user install it:
  - **macOS:** `brew install jq`
  - **Linux:** `sudo apt-get install jq` (or equivalent package manager)
  - **Windows (Git Bash):** Download `jq-windows-amd64.exe` from
    https://github.com/jqlang/jq/releases, rename to `jq.exe`, and place in a
    directory on PATH (e.g., `C:\Program Files\Git\usr\bin\`)
- An SSH keypair exists on the host (ask the user for the path to their public key
  if the default `~/.ssh/id_ed25519.pub` doesn't exist)

## 2. Select Features

Scan the `features/` directory for available features. For each one, read its
`feature.yaml` to get the `display_name` and `description`.

Present the list of available features to the user and ask which ones to enable.
Write their selection to `features.conf` (one feature name per line).

If `features.conf` already exists, show the current selection and ask if changes
are needed.

## 3. Assemble Build Artifacts

Run `bash build/assemble.sh` from the project root. This generates:
- `.generated/Dockerfile` (also copied to project root)
- `.generated/settings.json`
- `.generated/crontab`
- `.generated/config.yaml` (compiled from per-feature config snippets)
- `.generated/entrypoint.d/` hooks

If any enabled features didn't have a `config.snippet.yaml` yet, assemble.sh
auto-copies the `.example` file. The script will list which ones were created.

Verify the script completes without errors.

## 4. Configure

For each enabled feature, check its `features/<name>/config.snippet.yaml`.
Walk through each feature's config with the user, filling in their values
(repos, usernames, tokens, etc.).

If the snippet already has values from a previous setup, show its contents
and ask if changes are needed.

## 5. Feature-Specific Setup

For each enabled feature in `features.conf`, read that feature's `setup.md` file
(at `features/<name>/setup.md`) and walk the user through its steps.

## 6. Choose SSH Port

Ask the user what port to use for SSH into the container. Suggest a high,
uncommon port (avoid 2000-9999 range). Update the port in `docker-compose.yml`
if it differs from what's already configured.

## 7. Build the Docker Image

Run `docker compose build` from the project root. Wait for it to complete.

## 8. First Boot with SSH Key Injection

Using the SSH public key path from step 1:

- Read the public key contents
- Pass it as the `SSH_AUTHORIZED_KEY` environment variable
- Run `docker compose up -d`
- Wait 3–5 seconds for sshd to start (SSH connections will be refused if attempted immediately)
- Verify the container is running with `docker compose ps`

## 9. Add SSH Config Entry

Check the user's `~/.ssh/config` for an existing `claude-docker-worker` entry.

- If missing, append an entry using the port from step 6, the SSH key from step 1,
  and `User root` / `HostName 127.0.0.1`
- If present, verify the port matches and update if needed

## 10. Verify SSH Connectivity

Run `ssh -o StrictHostKeyChecking=accept-new claude-docker-worker "echo connected"`
to verify the connection works.

## 11. Install Claude Code Permissions

Copy the generated `settings.json` into the container:

```
docker cp .generated/settings.json claude-docker-worker:/root/.claude/settings.json
```

## 12. Authenticate Claude Code

Tell the user to SSH into the container and run the headless auth flow:

```
ssh claude-docker-worker
claude auth login --headless
```

Explain that they need to open the URL in their browser, complete OAuth, and paste
the code back. Wait for the user to confirm they've completed this step.

## 13. Final Verification

SSH into the container and verify everything is working:

- `claude --model opus -p "say hello"` — confirms Claude Code + Opus access
- `crontab -l` — confirms cron jobs are installed
- Check that `/opt/dockworker/config.yaml` exists and matches the project's `config.yaml`

For each enabled feature, run any feature-specific verification checks described
in its setup.md.

Report the results and confirm the setup is complete. Remind the user that:

- The container runs with `restart: always` and survives reboots
- Claude Code auth tokens may expire after 30 days of inactivity
- Features run on their own schedules as defined in the assembled crontab
- They can SSH in with `ssh claude-docker-worker` to inspect or debug
