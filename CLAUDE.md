# Claude Docker Worker

## Purpose

claude-docker-worker is a lightweight project for running Claude Code in a Docker container on a local machine. Features that make it into this repo should be integral to that core function.

The GitHub issue/PR automation included today is the first use case built on this foundation. Its scheduling, configuration, and extension points are still experimental and expected to evolve. Third-party integrations (Slack, Jira, custom dashboards, etc.) are planned as individual setup commands — similar to `/setup` — that users can opt into without affecting the core container. This roadmap is still taking shape.

## Architecture

- **Container**: Ubuntu 24.04 with Claude Code, GitHub CLI, cron, and SSH access
- **Persistence**: Named Docker volumes for credentials, config, workspace, and SSH keys
- **Scripts**: Bash scripts in `scripts/` orchestrate cron-driven automation loops
- **Config**: `config.yaml` holds machine-specific settings (repos, users, schedules). It is gitignored — `config.yaml.example` is the committed template.
- **Auth**: Claude Code OAuth stored on the `claude-config` volume. Optional GitHub App identity for bot-branded comments, with auto-discovery of installations.
- **Permissions**: `settings.json` controls what Claude Code can do in non-interactive mode. The `env` key injects environment variables (like `GH_TOKEN`) into Claude's session.

## Code Standards

### Shell Scripts

- Use `set -euo pipefail` at the top of every script
- Use `bash -l` invocations in cron to ensure PATH includes Claude Code
- Log only when there is meaningful output — silent no-ops on quiet cycles
- Use file-based locking (`flock`) to prevent script and repo collisions
- Keep config parsing in `common.sh`; individual scripts source it

### Prompt Engineering

Write Claude prompts in a clean, affirmative style:

- **State what to do**, with enough context that the right behavior is the obvious one
- Frame constraints as positive directions: "post your reply using `gh issue comment`" rather than prohibition-style wording
- Keep prompts focused on the task — avoid defensive padding or long lists of warnings
- Trust that well-structured permissions and environment (settings.json, GH_TOKEN injection) handle guardrails so the prompt can focus on the real work

### General

- Prefer editing existing files over creating new ones
- Keep the dependency footprint minimal — the Dockerfile should stay lean
- Configuration belongs in `config.yaml`, not hardcoded in scripts
- Secrets and machine-specific values stay out of the repo (`.gitignore`)

## Contributing

Contributions should extend Claude Code's capabilities inside Docker. Before submitting:

- **Alignment**: Changes should serve the core purpose — running Claude Code effectively in a container. Integration-specific features (Slack, Jira, etc.) should be designed as optional setup commands that users can install independently.
- **Completeness**: Submissions should work end-to-end. Experimental features are welcome when marked clearly in config and docs.
- **Clean AI practices**: Prompts and instructions should follow the affirmative style described above. Explain exactly what to do rather than listing prohibitions. Well-designed systems guide behavior through structure, not warnings.
- **Documentation**: Update `README.md`, `config.yaml.example`, and the `/setup` command when adding configurable features.
