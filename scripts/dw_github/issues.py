"""Issue scanning and evaluation — label-driven workflow for issue management.

Implements the dockworker:* label system:
- dockworker:ready       → ready for AI work
- dockworker:needs-info  → awaiting clarification
- dockworker:in-progress → currently being worked on
- dockworker:pr-open     → PR created
- dockworker:done        → completed
- dockworker:failed      → work failed
- dockworker:skip        → not suitable for AI

Per-repo concurrency for implementation work: if any issue has in-progress or
pr-open, skip new implementation. Evaluation/triage can still run.
"""

import json
from dataclasses import asdict, dataclass

from github import Github
from github.Issue import Issue as GhIssue
from github.Repository import Repository

from .config import WorkerConfig
from .labels import add_label, get_dockworker_labels, has_any_dockworker_label, remove_label


@dataclass
class IssueTask:
    """Represents an issue found for work or evaluation."""
    type: str  # "issue" or "evaluate"
    issue_number: int
    issue_title: str
    issue_body: str

    def to_json(self) -> str:
        return json.dumps(asdict(self))


def repo_has_active_work(gh: Github, repo_name: str, config: WorkerConfig) -> bool:
    """Check if any open issue in the repo has dockworker:in-progress or dockworker:pr-open.

    If either label is present on any issue, the repo is busy and should not take new work.
    """
    repo = gh.get_repo(repo_name)
    in_progress_label = config.label("in-progress")
    pr_open_label = config.label("pr-open")

    for label_name in (in_progress_label, pr_open_label):
        try:
            issues = repo.get_issues(state="open", labels=[repo.get_label(label_name)])
            if issues.totalCount > 0:
                return True
        except Exception:
            pass

    return False


def find_ready_issue(gh: Github, repo_name: str, config: WorkerConfig) -> IssueTask | None:
    """Find the oldest open issue with dockworker:ready label."""
    repo = gh.get_repo(repo_name)
    ready_label = config.label("ready")

    try:
        label_obj = repo.get_label(ready_label)
    except Exception:
        return None

    issues = repo.get_issues(
        state="open",
        labels=[label_obj],
        sort="created",
        direction="asc",
    )

    for issue in issues:
        if issue.pull_request:
            continue
        return IssueTask(
            type="issue",
            issue_number=issue.number,
            issue_title=issue.title,
            issue_body=issue.body or "",
        )

    return None


def find_unevaluated_issue(gh: Github, repo_name: str, config: WorkerConfig) -> IssueTask | None:
    """Find the oldest open issue with NO dockworker:* labels."""
    repo = gh.get_repo(repo_name)
    issues = repo.get_issues(
        state="open",
        sort="created",
        direction="asc",
    )

    for issue in issues:
        if issue.pull_request:
            continue
        if not has_any_dockworker_label(issue, config):
            return IssueTask(
                type="evaluate",
                issue_number=issue.number,
                issue_title=issue.title,
                issue_body=issue.body or "",
            )

    return None


def get_full_issue_context(gh: Github, repo_name: str, issue_number: int) -> dict:
    """Fetch complete issue context including comments and labels."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)

    return {
        "title": issue.title,
        "body": issue.body or "",
        "labels": [label.name for label in issue.labels],
        "comments": [
            {"author": c.user.login, "body": c.body}
            for c in issue.get_comments()
        ],
    }


def mark_evaluating(gh: Github, repo_name: str, issue_number: int, config: WorkerConfig) -> None:
    """Mark issue as currently being evaluated."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    add_label(issue, config.label("evaluating"))


def mark_in_progress(gh: Github, repo_name: str, issue_number: int, config: WorkerConfig) -> None:
    """Transition issue to in-progress: add in-progress label, remove ready."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    add_label(issue, config.label("in-progress"))
    remove_label(issue, config.label("ready"))


def mark_pr_open(gh: Github, repo_name: str, issue_number: int, config: WorkerConfig) -> None:
    """Transition issue to pr-open: add pr-open label, remove in-progress."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    add_label(issue, config.label("pr-open"))
    remove_label(issue, config.label("in-progress"))


def mark_failed(gh: Github, repo_name: str, issue_number: int, config: WorkerConfig) -> None:
    """Transition issue to failed: add failed label, remove in-progress."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    add_label(issue, config.label("failed"))
    remove_label(issue, config.label("in-progress"))


def mark_evaluated(
    gh: Github, repo_name: str, issue_number: int, result_label: str, config: WorkerConfig
) -> None:
    """Apply evaluation result label (ready, needs-info, or skip) and remove evaluating."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    add_label(issue, config.label(result_label))
    remove_label(issue, config.label("evaluating"))


def post_comment(gh: Github, repo_name: str, issue_number: int, body: str) -> None:
    """Post a comment on an issue."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    issue.create_comment(body)
