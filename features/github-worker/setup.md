## GitHub Worker Setup

These steps configure the GitHub Issue/PR Worker feature.

### GH-1. Configure GitHub Worker

Edit `features/github-worker/config.snippet.yaml` (created automatically from
the `.example` file by `assemble.sh` if it didn't exist).

Walk the user through filling in:

- Which GitHub repos to monitor (format: `owner/repo`)
- GitHub username(s) to add to `authorized_users`
- Whether to change the mention handle (default: `@dockworker`)
- Whether to change the bot signature (default: `— 🚢 Claude Dockworker`)
- Whether to change the label prefix (default: `dockworker`)

Write their answers into `features/github-worker/config.snippet.yaml`.

If the snippet already has values, show its contents and ask if changes are needed.

### GH-2. Choose Authentication Method

Ask the user how they want the bot to authenticate with GitHub:

#### Option A: GitHub App (Recommended)

This is the recommended option. The bot posts comments under its own identity
and can be installed on multiple accounts/orgs.

##### GH-2a-i. Create the GitHub App

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

##### GH-2a-ii. Record the App ID

Ask the user for the **App ID** shown on the app's settings page after creation.
Update `features/github-worker/config.snippet.yaml` with:

```yaml
app_id: "12345"
```

##### GH-2a-iii. Generate a Private Key

Tell the user to click "Generate a private key" on the app settings page.
A `.pem` file will download. Ask the user for the file path.
Store it temporarily — it will be copied into the container after first boot.

##### GH-2a-iv. Install the App

Tell the user to go to the "Install App" tab in their app settings and install
it on their account. They can choose "All repositories" or select specific ones.

Installations are auto-discovered at runtime — no need to specify an installation ID.
If the app is installed on multiple accounts or orgs, it will automatically use the
correct installation for each repo.

Wait for user to confirm.

#### Option B: Personal Account

The bot will use the user's personal GitHub CLI auth. Comments will be posted
under their personal account. No additional setup is needed here — GitHub CLI
auth happens in a later step.

### GH-3. Copy GitHub App Key (if applicable)

If the user chose GitHub App auth in GH-2, copy the private key into the container:

```
docker cp /path/to/key.pem claude-docker-worker:/root/.claude/github-app-key.pem
ssh claude-docker-worker "chmod 600 /root/.claude/github-app-key.pem"
```

### GH-4. Authenticate GitHub CLI (Option B only)

If the user chose Option B (personal account) in GH-2, tell them to run
`gh auth login` inside the container (while still SSH'd in), then run
`gh auth setup-git` to configure git credential forwarding.

If the user chose Option A (GitHub App), skip this step — the App token
handles all GitHub API interactions and no `gh` CLI auth is needed.

Wait for the user to confirm they've completed this step (or skipped it).

### GH-5. Set Up Dockworker Labels

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
