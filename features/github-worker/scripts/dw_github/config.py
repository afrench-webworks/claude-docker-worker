"""Config loader — reads config.yaml using PyYAML."""

import os
from dataclasses import dataclass, field

import yaml

DEFAULT_CONFIG_PATH = "/opt/dockworker/config.yaml"


@dataclass
class WorkerConfig:
    repos: list[str] = field(default_factory=list)
    authorized_users: list[str] = field(default_factory=list)
    mention: str = "@dockworker"
    bot_signature: str = "— 🚢 Claude Dockworker"
    git_bot_name: str = "claude-docker-worker"
    git_bot_email: str = "claude-docker-worker@noreply.github.com"
    app_id: str | None = None
    label_prefix: str = "dockworker"
    issue_work_window_start: int | None = None
    issue_work_window_end: int | None = None

    def label(self, name: str) -> str:
        """Build a full label name like 'dockworker:ready'."""
        return f"{self.label_prefix}:{name}"


def load_config(path: str | None = None) -> WorkerConfig:
    """Load config from YAML file. Falls back to env var CONFIG_FILE or default path."""
    if path is None:
        path = os.environ.get("CONFIG_FILE", DEFAULT_CONFIG_PATH)

    with open(path) as f:
        raw = yaml.safe_load(f) or {}

    config = WorkerConfig(
        repos=raw.get("repos", []),
        authorized_users=raw.get("authorized_users", []),
        mention=raw.get("mention", WorkerConfig.mention),
        bot_signature=raw.get("bot_signature", WorkerConfig.bot_signature),
        git_bot_name=raw.get("git_bot_name", WorkerConfig.git_bot_name),
        git_bot_email=raw.get("git_bot_email", WorkerConfig.git_bot_email),
        app_id=raw.get("app_id"),
        label_prefix=raw.get("label_prefix", WorkerConfig.label_prefix),
        issue_work_window_start=raw.get("issue_work_window_start"),
        issue_work_window_end=raw.get("issue_work_window_end"),
    )

    if not config.repos:
        raise ValueError("No repos configured in config.yaml")
    if not config.authorized_users:
        raise ValueError("No authorized_users configured in config.yaml")

    return config
