"""Label management — dockworker:* label system for issue workflow tracking."""

from github import Github, GithubException
from github.Issue import Issue
from github.Repository import Repository

from .config import WorkerConfig

# Label definitions: (suffix, color hex, description)
LABELS = [
    ("ready", "0e8a16", "Evaluated and ready for AI to work on"),
    ("evaluating", "c2e0c6", "Currently being evaluated for readiness"),
    ("needs-info", "fbca04", "Awaiting clarification — questions posted in comments"),
    ("in-progress", "1d76db", "Currently being worked on by the worker"),
    ("pr-open", "5319e7", "Pull request created, awaiting review"),
    ("done", "cccccc", "Completed successfully"),
    ("failed", "d93f0b", "Work attempt failed"),
    ("skip", "ffffff", "Not suitable for AI work"),
    ("reset", "e36209", "Reset issue — clear all dockworker state and re-evaluate"),
]


def ensure_labels(gh: Github, repo_name: str, config: WorkerConfig) -> None:
    """Create any missing dockworker:* labels in the repository."""
    repo = gh.get_repo(repo_name)
    existing = {label.name: label for label in repo.get_labels()}

    for suffix, color, description in LABELS:
        label_name = config.label(suffix)
        if label_name in existing:
            label = existing[label_name]
            if label.color != color or label.description != description:
                label.edit(label_name, color, description)
        else:
            repo.create_label(label_name, color, description)


def add_label(issue: Issue, label_name: str) -> None:
    """Add a label to an issue. No-op if already present."""
    try:
        issue.add_to_labels(label_name)
    except GithubException:
        pass


def remove_label(issue: Issue, label_name: str) -> None:
    """Remove a label from an issue. No-op if not present."""
    try:
        issue.remove_from_labels(label_name)
    except GithubException:
        pass


def has_any_dockworker_label(issue: Issue, config: WorkerConfig) -> bool:
    """Check if an issue has any dockworker:* label."""
    prefix = f"{config.label_prefix}:"
    return any(label.name.startswith(prefix) for label in issue.labels)


def get_dockworker_labels(issue: Issue, config: WorkerConfig) -> list[str]:
    """Get all dockworker:* label names on an issue."""
    prefix = f"{config.label_prefix}:"
    return [label.name for label in issue.labels if label.name.startswith(prefix)]
