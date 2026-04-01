"""Mention scanning — detects @mentions in issues and PRs.

Replaces the mention-scanning logic from handlers/mentions.sh.
"""

import json
from dataclasses import asdict, dataclass
from pathlib import Path

from github import Github
from github.PullRequest import PullRequest
from github.Repository import Repository

from .config import WorkerConfig

STATE_DIR = Path("/root/workspace/.issue-worker/state")
HANDLED_MENTIONS_FILE = STATE_DIR / "handled-mentions.json"


@dataclass
class Mention:
    id: str
    body: str
    user: str
    source: str  # pr-conversation, pr-review-comment, pr-review, issue-comment, issue-body
    number: int
    pr_branch: str | None = None
    path: str | None = None  # for review comments
    line: int | None = None  # for review comments
    review_id: str | None = None  # for review summaries

    def to_json(self) -> str:
        return json.dumps(asdict(self))


def _load_handled() -> dict[str, str]:
    """Load the set of already-handled mention IDs."""
    if not HANDLED_MENTIONS_FILE.exists():
        return {}
    try:
        return json.loads(HANDLED_MENTIONS_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _is_handled(mention_id: str, handled: dict[str, str]) -> bool:
    return mention_id in handled


def _is_bot_comment(body: str, config: WorkerConfig) -> bool:
    return config.bot_signature in body


def _has_mention(body: str, config: WorkerConfig) -> bool:
    return config.mention in body


def _is_authorized(user: str, config: WorkerConfig) -> bool:
    return user in config.authorized_users


def collect_mentions(gh: Github, repo_name: str, config: WorkerConfig) -> list[Mention]:
    """Gather all unhandled mentions from a repo's open PRs and issues."""
    repo = gh.get_repo(repo_name)
    handled = _load_handled()
    mentions: list[Mention] = []

    # --- PRs: conversation comments, review comments, review summaries ---
    for pr in repo.get_pulls(state="open"):
        branch = pr.head.ref

        # PR conversation comments (via issue comments API)
        for comment in pr.as_issue().get_comments():
            cid = str(comment.id)
            if _is_handled(cid, handled):
                continue
            mentions.append(Mention(
                id=cid,
                body=comment.body or "",
                user=comment.user.login,
                source="pr-conversation",
                number=pr.number,
                pr_branch=branch,
            ))

        # PR review comments (inline code comments)
        for comment in pr.get_review_comments():
            cid = str(comment.id)
            if _is_handled(cid, handled):
                continue
            mentions.append(Mention(
                id=cid,
                body=comment.body or "",
                user=comment.user.login,
                source="pr-review-comment",
                number=pr.number,
                pr_branch=branch,
                path=comment.path,
                line=comment.line,
            ))

        # PR reviews (summary comments)
        for review in pr.get_reviews():
            rid = str(review.id)
            if _is_handled(rid, handled):
                continue
            body = review.body or ""
            if not body:
                continue
            mentions.append(Mention(
                id=rid,
                body=body,
                user=review.user.login,
                source="pr-review",
                number=pr.number,
                pr_branch=branch,
                review_id=rid,
            ))

    # --- Issues: comments and bodies ---
    for issue in repo.get_issues(state="open"):
        if issue.pull_request:
            continue  # skip PRs (they show up in get_issues too)

        # Issue comments
        for comment in issue.get_comments():
            cid = str(comment.id)
            if _is_handled(cid, handled):
                continue
            mentions.append(Mention(
                id=cid,
                body=comment.body or "",
                user=comment.user.login,
                source="issue-comment",
                number=issue.number,
            ))

        # Issue body
        body_id = f"issue-body-{repo_name}#{issue.number}"
        if not _is_handled(body_id, handled):
            body = issue.body or ""
            if body:
                mentions.append(Mention(
                    id=body_id,
                    body=body,
                    user=issue.user.login,
                    source="issue-body",
                    number=issue.number,
                ))

    return mentions


def find_actionable_mention(
    gh: Github, repo_name: str, config: WorkerConfig
) -> Mention | None:
    """Find the first actionable mention (has @mention, not bot, authorized user)."""
    handled = _load_handled()
    all_mentions = collect_mentions(gh, repo_name, config)

    for mention in all_mentions:
        if not _has_mention(mention.body, config):
            continue
        if _is_bot_comment(mention.body, config):
            mark_mention_handled(mention.id)
            continue
        if not _is_authorized(mention.user, config):
            mark_mention_handled(mention.id)
            continue
        return mention

    return None


def mark_mention_handled(mention_id: str) -> None:
    """Record a mention as handled."""
    from datetime import datetime, timezone

    handled = _load_handled()
    handled[mention_id] = datetime.now(timezone.utc).isoformat()

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    HANDLED_MENTIONS_FILE.write_text(json.dumps(handled))


def build_context(gh: Github, repo_name: str, mention: Mention) -> dict:
    """Assemble full context for a mention response."""
    repo = gh.get_repo(repo_name)
    context: dict = {}

    if mention.source in ("pr-conversation", "pr-review-comment", "pr-review"):
        pr = repo.get_pull(mention.number)
        context["title"] = pr.title
        context["body"] = pr.body or ""
        context["comments"] = [
            {"author": c.user.login, "body": c.body}
            for c in pr.as_issue().get_comments()
        ]
        context["review_comments"] = [
            {"author": c.user.login, "path": c.path, "line": c.line, "body": c.body}
            for c in pr.get_review_comments()
        ]

        # Latest review
        reviews = list(pr.get_reviews())
        non_empty = [r for r in reviews if r.body]
        if non_empty:
            latest = non_empty[-1]
            review_ctx: dict = {"state": latest.state, "body": latest.body}

            # If this mention IS a review, include its inline comments
            if mention.source == "pr-review" and mention.review_id:
                try:
                    review_obj = pr.get_review(int(mention.review_id))
                    inline = [
                        {"path": c.path, "line": c.line, "body": c.body, "author": c.user.login}
                        for c in review_obj.get_comments()
                    ]
                    review_ctx["inline_comments"] = inline
                except Exception:
                    pass
            context["latest_review"] = review_ctx

    elif mention.source in ("issue-comment", "issue-body"):
        issue = repo.get_issue(mention.number)
        context["title"] = issue.title
        context["body"] = issue.body or ""
        context["comments"] = [
            {"author": c.user.login, "body": c.body}
            for c in issue.get_comments()
        ]

        # Check for linked PR (from processed-issues state)
        processed_file = STATE_DIR / "processed-issues.json"
        if processed_file.exists():
            try:
                processed = json.loads(processed_file.read_text())
                state_key = f"{repo_name}#{mention.number}"
                issue_state = processed.get(state_key, {})
                if isinstance(issue_state, dict) and issue_state.get("status") == "pr-opened":
                    context["linked_pr"] = issue_state.get("pr_url", "")
            except (json.JSONDecodeError, OSError):
                pass

    return context
