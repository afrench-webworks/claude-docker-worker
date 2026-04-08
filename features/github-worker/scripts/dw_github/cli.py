"""CLI entry points for the GitHub module.

Called from bash scripts via: python3 -m dw_github.cli <command> [args]
All commands output JSON to stdout for bash consumption.
"""

import argparse
import json
import sys

from .client import GitHubClientFactory
from .config import load_config


def cmd_auth(args: argparse.Namespace) -> None:
    """Authenticate and inject token for an owner into settings.json."""
    config = load_config()
    factory = GitHubClientFactory(config)

    from .auth import clear_token_from_settings, inject_token_into_settings

    token = factory.get_token(args.owner)
    if token:
        inject_token_into_settings(token)
        print(json.dumps({"status": "ok", "using_app": factory.using_app}))
    else:
        clear_token_from_settings()
        print(json.dumps({"status": "fallback", "using_app": False}))


def cmd_find_mention(args: argparse.Namespace) -> None:
    """Find the first actionable mention in a repo."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .mentions import find_actionable_mention

    mention = find_actionable_mention(gh, args.repo, config)
    if mention:
        print(mention.to_json())
    # Empty output = no work found (bash checks for empty string)


def cmd_find_issue(args: argparse.Namespace) -> None:
    """Find the oldest ready issue in a repo."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import find_ready_issue, repo_has_active_work

    if repo_has_active_work(gh, args.repo, config):
        # Repo is busy — output nothing
        return

    task = find_ready_issue(gh, args.repo, config)
    if task:
        print(task.to_json())


def cmd_find_unevaluated(args: argparse.Namespace) -> None:
    """Find the oldest unevaluated issue in a repo.

    Evaluation does NOT check for active work — the worker can triage
    issues even while waiting for a PR review or other in-progress task.
    """
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import find_unevaluated_issue

    task = find_unevaluated_issue(gh, args.repo, config)
    if task:
        print(task.to_json())


def cmd_check_active(args: argparse.Namespace) -> None:
    """Check if a repo has active work (in-progress or pr-open)."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import repo_has_active_work

    active = repo_has_active_work(gh, args.repo, config)
    print(json.dumps({"active": active}))


def cmd_check_pr_lifecycle(args: argparse.Namespace) -> None:
    """Check pr-open issues and transition to done if PR is merged/closed."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import check_pr_lifecycle

    transitions = check_pr_lifecycle(gh, args.repo, config)
    print(json.dumps({"status": "ok", "transitions": transitions}))


def cmd_process_resets(args: argparse.Namespace) -> None:
    """Process issues with dockworker:reset label — strip labels and return issue numbers."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import process_resets

    resets = process_resets(gh, args.repo, config)
    print(json.dumps({"status": "ok", "resets": resets}))


def cmd_ensure_labels(args: argparse.Namespace) -> None:
    """Ensure all dockworker:* labels exist in a repo."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .labels import ensure_labels

    ensure_labels(gh, args.repo, config)
    print(json.dumps({"status": "ok", "repo": args.repo}))


def cmd_comment(args: argparse.Namespace) -> None:
    """Post a comment on an issue/PR."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import post_comment

    post_comment(gh, args.repo, args.issue, args.body)
    print(json.dumps({"status": "ok"}))


def cmd_label(args: argparse.Namespace) -> None:
    """Add or remove a label on an issue."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    repo = gh.get_repo(args.repo)
    issue = repo.get_issue(args.issue)

    from .labels import add_label, remove_label

    if args.add:
        add_label(issue, args.add)
        print(json.dumps({"status": "ok", "action": "add", "label": args.add}))
    elif args.remove:
        remove_label(issue, args.remove)
        print(json.dumps({"status": "ok", "action": "remove", "label": args.remove}))


def cmd_create_pr(args: argparse.Namespace) -> None:
    """Create a pull request."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .pulls import create_pull_request

    pr_url = create_pull_request(
        gh, args.repo, args.head, args.title, args.body, base=args.base
    )
    print(json.dumps({"status": "ok", "pr_url": pr_url}))


def cmd_issue_context(args: argparse.Namespace) -> None:
    """Fetch full issue context (title, body, comments, labels)."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .issues import get_full_issue_context

    context = get_full_issue_context(gh, args.repo, args.issue)
    print(json.dumps(context))


def cmd_mention_context(args: argparse.Namespace) -> None:
    """Build full context for a mention response."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from .mentions import Mention, build_context

    # Reconstruct Mention from JSON passed via --mention-json
    mention_data = json.loads(args.mention_json)
    mention = Mention(**mention_data)

    context = build_context(gh, args.repo, mention)
    print(json.dumps(context))


def cmd_mark_mention_handled(args: argparse.Namespace) -> None:
    """Mark a mention as handled."""
    from .mentions import mark_mention_handled

    mark_mention_handled(args.mention_id)
    print(json.dumps({"status": "ok"}))


def cmd_prune_mentions(args: argparse.Namespace) -> None:
    """Prune handled-mention entries older than 30 days."""
    from .mentions import prune_handled_mentions

    removed = prune_handled_mentions()
    print(json.dumps({"status": "ok", "removed": removed}))


def cmd_mark_issue(args: argparse.Namespace) -> None:
    """Transition an issue's label state."""
    config = load_config()
    factory = GitHubClientFactory(config)
    owner = args.repo.split("/")[0]
    gh = factory.get_client(owner)

    from . import issues

    action_map = {
        "evaluating": issues.mark_evaluating,
        "in-progress": issues.mark_in_progress,
        "pr-open": issues.mark_pr_open,
        "failed": issues.mark_failed,
    }

    fn = action_map.get(args.state)
    if fn:
        fn(gh, args.repo, args.issue, config)
        print(json.dumps({"status": "ok", "state": args.state}))
    elif args.state in ("ready", "needs-info", "skip"):
        issues.mark_evaluated(gh, args.repo, args.issue, args.state, config)
        print(json.dumps({"status": "ok", "state": args.state}))
    else:
        print(json.dumps({"status": "error", "message": f"Unknown state: {args.state}"}))
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(prog="github-cli", description="GitHub module CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    # auth
    p = sub.add_parser("auth", help="Authenticate and inject token")
    p.add_argument("--owner", required=True)

    # find-mention
    p = sub.add_parser("find-mention", help="Find actionable mention")
    p.add_argument("--repo", required=True)

    # find-issue
    p = sub.add_parser("find-issue", help="Find ready issue")
    p.add_argument("--repo", required=True)

    # find-unevaluated
    p = sub.add_parser("find-unevaluated", help="Find unevaluated issue")
    p.add_argument("--repo", required=True)

    # check-active
    p = sub.add_parser("check-active", help="Check if repo has active work")
    p.add_argument("--repo", required=True)

    # check-pr-lifecycle
    p = sub.add_parser("check-pr-lifecycle", help="Transition pr-open issues to done if PR merged/closed")
    p.add_argument("--repo", required=True)

    # process-resets
    p = sub.add_parser("process-resets", help="Process dockworker:reset labels")
    p.add_argument("--repo", required=True)

    # ensure-labels
    p = sub.add_parser("ensure-labels", help="Ensure dockworker labels exist")
    p.add_argument("--repo", required=True)

    # comment
    p = sub.add_parser("comment", help="Post a comment")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", required=True, type=int)
    p.add_argument("--body", required=True)

    # label
    p = sub.add_parser("label", help="Add or remove a label")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", required=True, type=int)
    p.add_argument("--add", help="Label to add")
    p.add_argument("--remove", help="Label to remove")

    # create-pr
    p = sub.add_parser("create-pr", help="Create a pull request")
    p.add_argument("--repo", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--body", required=True)
    p.add_argument("--base", default=None)

    # issue-context
    p = sub.add_parser("issue-context", help="Fetch full issue context")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", required=True, type=int)

    # mention-context
    p = sub.add_parser("mention-context", help="Build context for mention response")
    p.add_argument("--repo", required=True)
    p.add_argument("--mention-json", required=True)

    # mark-mention-handled
    p = sub.add_parser("mark-mention-handled", help="Mark mention as handled")
    p.add_argument("--mention-id", required=True)

    # prune-mentions
    sub.add_parser("prune-mentions", help="Prune handled-mention entries older than 30 days")

    # mark-issue
    p = sub.add_parser("mark-issue", help="Transition issue label state")
    p.add_argument("--repo", required=True)
    p.add_argument("--issue", required=True, type=int)
    p.add_argument("--state", required=True,
                   choices=["evaluating", "in-progress", "pr-open", "failed", "ready", "needs-info", "skip"])

    args = parser.parse_args()

    commands = {
        "auth": cmd_auth,
        "find-mention": cmd_find_mention,
        "find-issue": cmd_find_issue,
        "find-unevaluated": cmd_find_unevaluated,
        "check-active": cmd_check_active,
        "check-pr-lifecycle": cmd_check_pr_lifecycle,
        "process-resets": cmd_process_resets,
        "ensure-labels": cmd_ensure_labels,
        "comment": cmd_comment,
        "label": cmd_label,
        "create-pr": cmd_create_pr,
        "issue-context": cmd_issue_context,
        "mention-context": cmd_mention_context,
        "mark-mention-handled": cmd_mark_mention_handled,
        "prune-mentions": cmd_prune_mentions,
        "mark-issue": cmd_mark_issue,
    }

    commands[args.command](args)


if __name__ == "__main__":
    main()
