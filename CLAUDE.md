# Claude Docker Worker

## Purpose

claude-docker-worker is a lightweight project for running Claude Code in a Docker container on a local machine. Features that make it into this repo should be integral to that core function.

Capabilities are organized as **features** — self-contained modules in `features/` that users enable in `features.conf`. The GitHub issue/PR worker is the first feature built on this foundation. New features (dev environments, integrations, custom stacks) can be added without modifying the core.

## Architecture

- **Container**: Ubuntu 24.04 with Claude Code, cron, and SSH access. Feature-specific tools (GitHub CLI, Flutter, etc.) are installed only when that feature is enabled.
- **Features**: Self-contained directories in `features/` with a `feature.yaml` manifest, Dockerfile snippet, settings/crontab/config snippets, entrypoint hooks, setup instructions, and scripts. Enabled via `features.conf`.
- **Build**: `build/assemble.sh` reads `features.conf` and composes the Dockerfile, settings.json, crontab, and entrypoint hooks from `core/` + enabled features into `.generated/`.
- **Persistence**: Named Docker volumes for credentials, config, workspace, and SSH keys.
- **Config**: Each feature has a `config.snippet.yaml.example` (committed) and `config.snippet.yaml` (gitignored, user-edited). `assemble.sh` compiles enabled snippets into `.generated/config.yaml` for the container. Configuration belongs in `config.yaml`, not hardcoded in scripts.
- **Auth**: Claude Code OAuth stored on the `claude-config` volume. Feature-specific auth (e.g., GitHub App) is handled by each feature.
- **Permissions**: `settings.json` is assembled from `core/settings.json.base` + feature snippets. The `env` key injects environment variables (like `GH_TOKEN`) into Claude's session.

## Code Standards

### Shell Scripts

- Use `set -euo pipefail` at the top of every script
- Use `bash -l` invocations in cron to ensure PATH includes Claude Code
- Log only when there is meaningful output — silent no-ops on quiet cycles
- Use file-based locking (`flock`) to prevent script and repo collisions
- Keep config parsing in `common.sh`; individual scripts source it
- Feature scripts live in `features/<name>/scripts/`; config is read from `/opt/dockworker/config.yaml`

### Prompt Engineering

Write Claude prompts in a clean, affirmative style:

- **State what to do**, with enough context that the right behavior is the obvious one
- Frame constraints as positive directions: "post your reply using `gh issue comment`" rather than prohibition-style wording
- Keep prompts focused on the task — avoid defensive padding or long lists of warnings
- Trust that well-structured permissions and environment (settings.json, GH_TOKEN injection) handle guardrails so the prompt can focus on the real work

### General

- Prefer editing existing files over creating new ones
- Keep the dependency footprint minimal — the Dockerfile should stay lean
- Configuration belongs in `config.snippet.yaml`, not hardcoded in scripts
- Secrets and machine-specific values stay out of the repo (`.gitignore`)

## Contributing

Contributions should extend Claude Code's capabilities inside Docker. Before submitting:

- **Alignment**: Changes should serve the core purpose — running Claude Code effectively in a container.
- **Features as modules**: New capabilities should be self-contained features in `features/<name>/` with a `feature.yaml` manifest. Each feature provides its own Dockerfile snippet, settings/crontab/config snippets, entrypoint hooks, setup steps, and scripts. See existing features for the pattern.
- **Completeness**: Submissions should work end-to-end. Experimental features are welcome when marked clearly in config and docs.
- **Clean AI practices**: Prompts and instructions should follow the affirmative style described above. Explain exactly what to do rather than listing prohibitions. Well-designed systems guide behavior through structure, not warnings.
- **Documentation**: Update `README.md` and the feature's `setup.md` when adding configurable features. Run `bash build/assemble.sh` to regenerate build artifacts after changes.
