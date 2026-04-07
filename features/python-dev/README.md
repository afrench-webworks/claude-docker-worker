# Python Development Environment

Pre-installs Python development tooling so Claude Code can write, lint, test, and format Python code inside the container.

## What's Included

| Tool | Purpose |
|---|---|
| `python3` | Python interpreter (from Ubuntu base) |
| `pip3` | Package manager |
| `python3-venv` | Virtual environment support |
| `pytest` | Testing framework |
| `black` | Code formatter |
| `ruff` | Fast linter |
| `mypy` | Static type checker |
| `ipython` | Interactive Python shell |
| `virtualenv` | Virtual environment manager |
| `poetry` | Dependency management and packaging |

## Permissions

Claude Code is allowed to run all of the above commands. The permissions are merged into `settings.json` at build time.

## Configuration

This feature has no runtime configuration. Enable it in `features.conf` and rebuild.

## Usage

Once the container is built with this feature enabled, Claude Code can use all the tools directly:

```bash
ssh claude-docker-worker

# Claude can run these in its sessions:
pytest tests/
black --check src/
ruff check .
mypy src/
poetry install
```
