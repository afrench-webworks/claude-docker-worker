"""GitHub client factory — returns authenticated PyGithub instances."""

from github import Auth, Github

from .auth import (
    GitHubAppAuth,
    PersonalTokenAuth,
    clear_token_from_settings,
    inject_token_into_settings,
)
from .config import WorkerConfig


class GitHubClientFactory:
    """Creates authenticated GitHub clients based on config.

    If a GitHub App is configured, uses App installation tokens.
    Otherwise falls back to personal token auth.
    """

    def __init__(self, config: WorkerConfig):
        self.config = config
        self._app_auth: GitHubAppAuth | None = None
        self._personal_auth = PersonalTokenAuth()

        if config.app_id:
            try:
                self._app_auth = GitHubAppAuth(config.app_id)
                if not self._app_auth.has_installations:
                    print("[WARN] GitHub App has no installations, falling back to personal auth")
                    self._app_auth = None
            except Exception as e:
                print(f"[WARN] GitHub App init failed ({e}), falling back to personal auth")
                self._app_auth = None

    def get_client(self, owner: str) -> Github:
        """Get an authenticated PyGithub client for the given repo owner.

        Also injects the token into settings.json for Claude Code's gh CLI usage.
        """
        if self._app_auth:
            token = self._app_auth.get_token(owner)
            if token:
                inject_token_into_settings(token)
                return Github(auth=Auth.Token(token))
            # No installation for this owner — fall back
            clear_token_from_settings()

        token = self._personal_auth.get_token()
        if token:
            return Github(auth=Auth.Token(token))

        raise RuntimeError(
            f"No authentication available for {owner}. "
            "Configure a GitHub App or authenticate with `gh auth login`."
        )

    def get_token(self, owner: str) -> str | None:
        """Get a raw token string for the given owner (for gh CLI injection)."""
        if self._app_auth:
            token = self._app_auth.get_token(owner)
            if token:
                return token

        return self._personal_auth.get_token()

    @property
    def using_app(self) -> bool:
        return self._app_auth is not None
