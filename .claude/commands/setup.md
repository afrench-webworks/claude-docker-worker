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
- Ask the user for their GitHub username(s) to add to `authorized_users`
- Ask if they want to change the mention handle (default: `@dockworker`)
- Ask if they want to change the bot signature (default: `— 🚢 Claude Dockworker`)
- Ask if they want to change the label prefix (default: `dockworker`)
- Write their answers into `config.yaml`

If `config.yaml` already exists, show its contents and ask if changes are needed.

## 3. Choose Authentication Method

Ask the user how they want the bot to authenticate with GitHub:

### Option A: GitHub App (Recommended)

This is the recommended option. The bot posts comments under its own identity
and can be installed on multiple accounts/orgs.

#### 3a-i. Create the GitHub App

Tell the user to go to https://github.com/settings/apps/new and fill in:

- **App name:** Suggest `{username}-dockworker` (e.g., `jsmith-dockworker`)
- **Homepage URL:** Can be anything (e.g., their GitHub profile URL)
- **Webhook:** Uncheck "Active" (we poll, no webhooks needed)
- **Permissions:**
  - Repository > Contents: Read & write
  - Repository > Issues: Read & write
  - Repository > Pull requests: Read & write
  - Repository > Metadata: Read-only (auto-selected)
- **Where can this app be installed?** "Only on this account"

Click "Create GitHub App." Wait for user to confirm.

#### 3a-ii. Record the App ID

Ask the user for the **App ID** shown on the app's settings page after creation.
Update `config.yaml` with:

```yaml
app_id: "12345"
```

#### 3a-iii. Generate a Private Key

Tell the user to click "Generate a private key" on the app settings page.
A `.pem` file will download. Ask the user for the file path.
Store it temporarily — it will be copied into the container after first boot.

#### 3a-iv. Install the App

Tell the user to go to the "Install App" tab in their app settings and install
it on their account. They can choose "All repositories" or select specific ones.

Installations are auto-discovered at runtime — no need to specify an installation ID.
If the app is installed on multiple accounts or orgs, it will automatically use the
correct installation for each repo.

Wait for user to confirm.

### Option B: Personal Account

The bot will use the user's personal GitHub CLI auth. Comments will be posted
under their personal account. No additional setup is needed here — GitHub CLI
auth happens in a later step.

## 4. Choose SSH Port

Ask the user what port to use for SSH into the container. Suggest a high,
uncommon port (avoid 2000-9999 range). Update the port in `docker-compose.yml`
if it differs from what's already configured.

## 5. Build the Docker Image

Run `docker compose build` from the project root. Wait for it to complete.

## 6. First Boot with SSH Key Injection

Using the SSH public key path from step 1:

- Read the public key contents
- Pass it as the `SSH_AUTHORIZED_KEY` environment variable
- Run `docker compose up -d`
- Wait 3–5 seconds for sshd to start (SSH connections will be refused if attempted immediately)
- Verify the container is running with `docker compose ps`

## 7. Add SSH Config Entry

Check the user's `~/.ssh/config` for an existing `claude-docker-worker` entry.

- If missing, append an entry using the port from step 4, the SSH key from step 1,
  and `User root` / `HostName 127.0.0.1`
- If present, verify the port matches and update if needed

## 8. Verify SSH Connectivity

Run `ssh -o StrictHostKeyChecking=accept-new claude-docker-worker "echo connected"`
to verify the connection works.

## 9. Install Claude Code Permissions

Copy `settings.json.example` into the container at `/root/.claude/settings.json`:

```
docker cp settings.json.example claude-docker-worker:/root/.claude/settings.json
```

## 10. Copy GitHub App Key (if applicable)

If the user chose GitHub App auth in step 3, copy the private key into the container:

```
docker cp /path/to/key.pem claude-docker-worker:/root/.claude/github-app-key.pem
ssh claude-docker-worker "chmod 600 /root/.claude/github-app-key.pem"
```

## 11. Authenticate Claude Code

Tell the user to SSH into the container and run the headless auth flow:

```
ssh claude-docker-worker
claude auth login --headless
```

Explain that they need to open the URL in their browser, complete OAuth, and paste
the code back. Wait for the user to confirm they've completed this step.

## 12. Authenticate GitHub CLI (Option B only)

If the user chose Option B (personal account) in step 3, tell them to run
`gh auth login` inside the container (while still SSH'd in), then run
`gh auth setup-git` to configure git credential forwarding.

If the user chose Option A (GitHub App), skip this step — the App token
handles all GitHub API interactions and no `gh` CLI auth is needed.

Wait for the user to confirm they've completed this step (or skipped it).

## 13. Set Up Dockworker Labels

Ensure the `dockworker:*` labels are created in all configured repos. Run inside
the container:

```
ssh claude-docker-worker
```

For each repo in config.yaml, run:

```
python3 -m dw_github.cli ensure-labels --repo owner/repo-name
```

This creates these labels if they don't already exist:
- `dockworker:ready` (green) — Evaluated and ready for AI to work on
- `dockworker:needs-info` (yellow) — Awaiting clarification
- `dockworker:in-progress` (blue) — Currently being worked on
- `dockworker:pr-open` (purple) — Pull request created
- `dockworker:done` (grey) — Completed successfully
- `dockworker:failed` (red) — Work attempt failed
- `dockworker:skip` (white) — Not suitable for AI work

## 14. Final Verification

SSH into the container and verify everything is working:

- `claude --model opus -p "say hello"` — confirms Claude Code + Opus access
- `crontab -l` — confirms cron jobs are installed
- Check that `/opt/issue-worker/config.yaml` matches the project's `config.yaml`
- `python3 -m dw_github.cli check-active --repo owner/repo-name` — confirms Python module and GitHub auth work
- If using Option B (personal account): `gh auth status` — confirms GitHub CLI auth

Report the results and confirm the setup is complete. Remind the user that:

- The container runs with `restart: always` and survives reboots
- Claude Code auth tokens may expire after 30 days of inactivity
- The unified worker runs every 5 minutes, handling both mentions and issues
- Mentions are processed 24/7; issue processing runs 24/7 by default (configurable)
- Issues without `dockworker:*` labels are auto-evaluated and triaged
- Issues labeled `dockworker:ready` are picked up for implementation
- Only one issue per repo is worked on at a time (concurrency protection)
- They can test with `ssh claude-docker-worker` then `/opt/issue-worker/worker.sh`
