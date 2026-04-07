"""Pull request operations — create and manage PRs via PyGithub."""

from github import Github
from github.Repository import Repository


def create_pull_request(
    gh: Github,
    repo_name: str,
    head: str,
    title: str,
    body: str,
    base: str | None = None,
) -> str:
    """Create a pull request. Returns the PR URL.

    If base is not specified, uses the repo's default branch.
    """
    repo = gh.get_repo(repo_name)
    if base is None:
        base = repo.default_branch

    pr = repo.create_pull(
        title=title,
        body=body,
        head=head,
        base=base,
    )
    return pr.html_url


def get_pr_branch(gh: Github, repo_name: str, pr_number: int) -> str | None:
    """Get the head branch name of a PR."""
    repo = gh.get_repo(repo_name)
    try:
        pr = repo.get_pull(pr_number)
        return pr.head.ref
    except Exception:
        return None
