"""GitHub authentication — App JWT tokens and personal token fallback.

Replaces scripts/github-app-token.sh with a Python implementation.
"""

import json
import os
import subprocess
import time
from pathlib import Path

import jwt
from github import Auth, Github, GithubIntegration

APP_KEY_FILE = Path("/root/.claude/github-app-key.pem")
TOKEN_CACHE_DIR = Path("/root/.claude/app-token-cache")
CLAUDE_SETTINGS_FILE = Path("/root/.claude/settings.json")

# Tokens are valid for 1 hour; reuse cached ones for up to 50 minutes
TOKEN_CACHE_TTL = 50 * 60


class GitHubAppAuth:
    """Authenticates as a GitHub App installation using JWT + installation tokens."""

    def __init__(self, app_id: str, key_file: Path = APP_KEY_FILE):
        self.app_id = app_id
        self.private_key = key_file.read_text()
        self._installations: dict[str, int] = {}  # owner -> installation_id
        TOKEN_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        self._discover_installations()

    def _generate_jwt(self) -> str:
        now = int(time.time())
        payload = {
            "iat": now - 60,
            "exp": now + 600,
            "iss": self.app_id,
        }
        return jwt.encode(payload, self.private_key, algorithm="RS256")

    def _discover_installations(self) -> None:
        """Query /app/installations to map owner -> installation_id."""
        auth = Auth.AppAuth(int(self.app_id), self.private_key)
        gi = GithubIntegration(auth=auth)
        for installation in gi.get_installations():
            login = installation.raw_data.get("account", {}).get("login", "")
            if login:
                self._installations[login] = installation.id

    def get_installation_id(self, owner: str) -> int | None:
        return self._installations.get(owner)

    def get_token(self, owner: str) -> str | None:
        """Get an installation access token for the given owner. Uses cache."""
        installation_id = self.get_installation_id(owner)
        if installation_id is None:
            return None

        # Check cache
        cache_file = TOKEN_CACHE_DIR / f"{installation_id}.json"
        if cache_file.exists():
            try:
                cached = json.loads(cache_file.read_text())
                token = cached.get("token", "")
                expires_at = cached.get("expires_at", 0)
                if token and (expires_at - time.time()) > 600:
                    return token
            except (json.JSONDecodeError, KeyError):
                pass

        # Generate fresh token via PyGithub
        try:
            auth = Auth.AppAuth(int(self.app_id), self.private_key)
            gi = GithubIntegration(auth=auth)
            token = gi.get_access_token(installation_id).token
            # Cache with expiry timestamp
            expires_at = time.time() + 3600  # 1 hour from now
            cache_file.write_text(json.dumps({
                "token": token,
                "expires_at": expires_at,
            }))
            cache_file.chmod(0o600)
            return token
        except Exception as e:
            print(f"[ERROR] Failed to get installation token for {owner}: {e}")
            return None

    @property
    def has_installations(self) -> bool:
        return len(self._installations) > 0


class PersonalTokenAuth:
    """Authenticates using a personal token from GH_TOKEN env or gh CLI."""

    def __init__(self):
        self._token: str | None = None

    def get_token(self) -> str | None:
        if self._token:
            return self._token

        # Try environment variable first
        token = os.environ.get("GH_TOKEN", "")
        if token:
            self._token = token
            return token

        # Fall back to gh CLI
        try:
            result = subprocess.run(
                ["gh", "auth", "token"],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0 and result.stdout.strip():
                self._token = result.stdout.strip()
                return self._token
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

        return None


def inject_token_into_settings(token: str) -> None:
    """Write GH_TOKEN into Claude's settings.json env section."""
    if not CLAUDE_SETTINGS_FILE.exists():
        return
    try:
        settings = json.loads(CLAUDE_SETTINGS_FILE.read_text())
        if "env" not in settings:
            settings["env"] = {}
        settings["env"]["GH_TOKEN"] = token
        CLAUDE_SETTINGS_FILE.write_text(json.dumps(settings, indent=2))
    except (json.JSONDecodeError, OSError) as e:
        print(f"[WARN] Could not inject token into settings.json: {e}")


def clear_token_from_settings() -> None:
    """Remove GH_TOKEN from settings.json so gh CLI auth takes over."""
    if not CLAUDE_SETTINGS_FILE.exists():
        return
    try:
        settings = json.loads(CLAUDE_SETTINGS_FILE.read_text())
        if "env" in settings and "GH_TOKEN" in settings["env"]:
            del settings["env"]["GH_TOKEN"]
            CLAUDE_SETTINGS_FILE.write_text(json.dumps(settings, indent=2))
    except (json.JSONDecodeError, OSError) as e:
        print(f"[WARN] Could not clear token from settings.json: {e}")
