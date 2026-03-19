Set up the Claude Docker Worker on this machine. Walk through each step below,
verifying prerequisites before proceeding and asking the user for input where noted.
Stop and report if any step fails.

## 1. Verify Prerequisites

Check that the following are available. If any are missing, stop and tell the user
what needs to be installed before continuing.

- Docker Desktop is installed and the engine is running (`docker info`)
- Docker Compose v2 is available (`docker compose version`)
- An SSH keypair exists on the host (ask the user for the path to their public key
  if the default `~/.ssh/id_ed25519.pub` doesn't exist)

## 2. Create config.yaml

Check if `config.yaml` exists in the project root. If not:

- Copy `config.yaml.example` to `config.yaml`
- Ask the user which GitHub repos to monitor (format: `owner/repo`)
- Ask if they want to change the trigger label (default: `claude-task`)
- Ask if they want to change the mention handle (default: `@dockworker`)
- Ask if they want to change the bot signature (default: `— 🚢 Claude Dockworker`)
- Write their answers into `config.yaml`

If `config.yaml` already exists, show its contents and ask if changes are needed.

## 3. Choose SSH Port

Ask the user what port to use for SSH into the container. Suggest a high,
uncommon port (avoid 2000-9999 range). Update the port in `docker-compose.yml`
if it differs from what's already configured.

## 4. Build the Docker Image

Run `docker compose build` from the project root. Wait for it to complete.

## 5. First Boot with SSH Key Injection

Using the SSH public key path from step 1:

- Read the public key contents
- Pass it as the `SSH_AUTHORIZED_KEY` environment variable
- Run `docker compose up -d`
- Wait a few seconds, then verify the container is running with `docker compose ps`

## 6. Add SSH Config Entry

Check the user's `~/.ssh/config` for an existing `claude-docker-worker` entry.

- If missing, append an entry using the port from step 3, the SSH key from step 1,
  and `User root` / `HostName 127.0.0.1`
- If present, verify the port matches and update if needed

## 7. Verify SSH Connectivity

Run `ssh -o StrictHostKeyChecking=accept-new claude-docker-worker "echo connected"`
to verify the connection works.

## 8. Install Claude Code Permissions

Copy `settings.json.example` into the container at `/root/.claude/settings.json`:

```
docker cp settings.json.example claude-docker-worker:/root/.claude/settings.json
```

## 9. Authenticate Claude Code

Tell the user to SSH into the container and run the headless auth flow:

```
ssh claude-docker-worker
claude auth login --headless
```

Explain that they need to open the URL in their browser, complete OAuth, and paste
the code back. Wait for the user to confirm they've completed this step.

## 10. Authenticate GitHub CLI

Tell the user to run `gh auth login` inside the container (while still SSH'd in),
then run `gh auth setup-git` to configure git credential forwarding.

Wait for the user to confirm they've completed this step.

## 11. Final Verification

SSH into the container and verify everything is working:

- `claude --model opus -p "say hello"` — confirms Claude Code + Opus access
- `gh auth status` — confirms GitHub CLI auth
- `crontab -l` — confirms cron jobs are installed
- Check that `/opt/issue-worker/config.yaml` matches the project's `config.yaml`

Report the results and confirm the setup is complete. Remind the user that:

- The container runs with `restart: always` and survives reboots
- Claude Code auth tokens may expire after 30 days of inactivity
- The comment monitor runs every 5 minutes and responds to `@dockworker` mentions
- The issue worker runs midnight–8AM and picks up issues labeled with their trigger label
- They can test with `ssh claude-docker-worker` then `/opt/issue-worker/comment-monitor.sh`
