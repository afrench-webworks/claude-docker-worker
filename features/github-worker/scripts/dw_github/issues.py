"""Issue scanning and evaluation — label-driven workflow for issue management.

Implements the dockworker:* label system:
- dockworker:ready       → ready for AI work
- dockworker:needs-info  → awaiting clarification
- dockworker:in-progress → currently being worked on
- dockworker:pr-open     → PR created
- dockworker:done        → completed
- dockworker:failed      → work failed
- dockworker:skip        → not suitable for AI
- dockworker:reset       → clear all state and re-evaluate

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


def _first_matching(issues, *, task_type: str, predicate=None) -> IssueTask | None:
    """Return the first non-PR issue matching an optional predicate."""
    for issue in issues:
        if issue.pull_request:
            continue
        if predicate and not predicate(issue):
            continue
        return IssueTask(
            type=task_type,
            issue_number=issue.number,
            issue_title=issue.title,
            issue_body=issue.body or "",
        )
    return None


def find_ready_issue(gh: Github, repo_name: str, config: WorkerConfig) -> IssueTask | None:
    """Find the oldest open issue with dockworker:ready label.

    Bug-labeled issues are prioritized — the oldest ready bug is returned
    before any non-bug ready issue.
    """
    repo = gh.get_repo(repo_name)

    try:
        ready_label_obj = repo.get_label(config.label("ready"))
    except Exception:
        return None

    # Priority pass: oldest ready issue with a "bug" label
    try:
        bug_label_obj = repo.get_label("bug")
        result = _first_matching(
            repo.get_issues(
                state="open",
                labels=[ready_label_obj, bug_label_obj],
                sort="created",
                direction="asc",
            ),
            task_type="issue",
        )
        if result:
            return result
    except Exception:
        pass  # No "bug" label in repo — skip priority pass

    # Standard pass: oldest ready issue
    return _first_matching(
        repo.get_issues(
            state="open",
            labels=[ready_label_obj],
            sort="created",
            direction="asc",
        ),
        task_type="issue",
    )


def find_unevaluated_issue(gh: Github, repo_name: str, config: WorkerConfig) -> IssueTask | None:
    """Find the oldest open issue with NO dockworker:* labels.

    Bug-labeled issues are prioritized — the oldest unevaluated bug is
    returned before any non-bug unevaluated issue.
    """
    repo = gh.get_repo(repo_name)
    no_dw = lambda issue: not has_any_dockworker_label(issue, config)

    # Priority pass: oldest bug-labeled issue without dockworker labels
    try:
        bug_label_obj = repo.get_label("bug")
        result = _first_matching(
            repo.get_issues(
                state="open",
                labels=[bug_label_obj],
                sort="created",
                direction="asc",
            ),
            task_type="evaluate",
            predicate=no_dw,
        )
        if result:
            return result
    except Exception:
        pass  # No "bug" label in repo — skip priority pass

    # Standard pass: oldest issue without dockworker labels
    return _first_matching(
        repo.get_issues(
            state="open",
            sort="created",
            direction="asc",
        ),
        task_type="evaluate",
        predicate=no_dw,
    )


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


def check_pr_lifecycle(gh: Github, repo_name: str, config: WorkerConfig) -> list[dict]:
    """Check issues with dockworker:pr-open and transition based on PR state.

    Finds all open issues with the pr-open label, looks for a linked PR
    (via the processed-issues state or by scanning for a claude/issue-N branch PR),
    and transitions: merged → dockworker:done, closed without merge → dockworker:failed.

    Returns a list of transitions made (for logging).
    """
    from pathlib import Path

    repo = gh.get_repo(repo_name)
    pr_open_label = config.label("pr-open")
    transitions = []

    try:
        label_obj = repo.get_label(pr_open_label)
    except Exception:
        return transitions

    # Load processed-issues state for PR URL lookups (open issues only)
    state_file = Path("/root/workspace/.github-worker/state/processed-issues.json")
    processed_state = {}
    if state_file.exists():
        try:
            processed_state = json.loads(state_file.read_text())
        except (json.JSONDecodeError, OSError):
            pass

    # Check both open and closed issues — GitHub auto-closes issues
    # via "Fixes #N" syntax, so pr-open may be on closed issues too.
    for state in ("open", "closed"):
        issues = repo.get_issues(state=state, labels=[label_obj])

        for issue in issues:
            if issue.pull_request:
                continue

            if state == "closed":
                # Issue already closed (e.g., via "Fixes #N") — just swap the label
                add_label(issue, config.label("done"))
                remove_label(issue, config.label("pr-open"))
                transitions.append({
                    "issue": issue.number,
                    "status": "closed",
                })
                continue

            # Open issue — check if the linked PR has been merged/closed
            pr = _find_linked_pr(repo, repo_name, issue.number, processed_state)
            if pr is None:
                continue

            if pr.merged:
                add_label(issue, config.label("done"))
                remove_label(issue, config.label("pr-open"))
                transitions.append({
                    "issue": issue.number,
                    "pr": pr.number,
                    "status": "merged",
                })
            elif pr.state == "closed":
                add_label(issue, config.label("failed"))
                remove_label(issue, config.label("pr-open"))
                transitions.append({
                    "issue": issue.number,
                    "pr": pr.number,
                    "status": "closed-without-merge",
                })

    return transitions


def process_resets(gh: Github, repo_name: str, config: WorkerConfig) -> list[dict]:
    """Find issues with dockworker:reset and strip all dockworker state.

    For each open issue with the reset label:
    1. Remove ALL dockworker:* labels (including reset itself)
    2. Post a comment noting the reset

    Returns a list of {"issue": N} dicts so the caller can clear state files
    and delete stale remote branches.
    """
    repo = gh.get_repo(repo_name)
    reset_label = config.label("reset")
    resets = []

    try:
        label_obj = repo.get_label(reset_label)
    except Exception:
        return resets

    for issue in repo.get_issues(state="open", labels=[label_obj]):
        if issue.pull_request:
            continue

        # Remove every dockworker:* label
        for label_name in get_dockworker_labels(issue, config):
            remove_label(issue, label_name)

        issue.create_comment(
            f"All dockworker labels and state have been cleared. "
            f"This issue will be re-evaluated on the next worker cycle.\n\n"
            f"{config.bot_signature}"
        )

        resets.append({"issue": issue.number})

    return resets


def _find_linked_pr(repo, repo_name: str, issue_number: int, processed: dict):
    """Find the PR linked to an issue, via state file or branch convention."""
    # Check processed-issues state for a stored PR URL
    state_key = f"{repo_name}#{issue_number}"
    issue_state = processed.get(state_key, {})
    if isinstance(issue_state, dict):
        pr_url = issue_state.get("pr_url", "")
        if pr_url:
            # Extract PR number from URL (e.g., .../pull/8)
            try:
                pr_number = int(pr_url.rstrip("/").split("/")[-1])
                return repo.get_pull(pr_number)
            except (ValueError, Exception):
                pass

    # Fall back to branch naming convention: claude/issue-N
    branch_name = f"claude/issue-{issue_number}"
    for pr in repo.get_pulls(state="all", head=f"{repo.owner.login}:{branch_name}"):
        return pr

    return None


def post_comment(gh: Github, repo_name: str, issue_number: int, body: str) -> None:
    """Post a comment on an issue."""
    repo = gh.get_repo(repo_name)
    issue = repo.get_issue(issue_number)
    issue.create_comment(body)
