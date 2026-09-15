"""Small Nullafi client used by the Phase 1 local proof of concept.

This module intentionally keeps a narrow surface area: it knows how to call
Nullafi's scan endpoint and turn common HTTP/network failures into clear Python
exceptions. Later Snowflake stored procedures can reuse the same request and
parsing expectations without inheriting local-script concerns.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from typing import Any

import requests


DEFAULT_TIMEOUT_SECONDS = 15


class NullafiAPIError(RuntimeError):
    """Raised when Nullafi returns an error or cannot be reached cleanly."""

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        response_body: Any | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body


@dataclass(frozen=True)
class NullafiConfig:
    """Runtime configuration for Nullafi API calls.

    `scan_path` is configurable because Nullafi environments may expose either
    a base API host plus `/scan`, or a base URL that already includes an `/api`
    prefix. The Phase 0 notes confirmed `/scan` as the endpoint path.
    """

    api_key: str
    namespace: str
    base_url: str
    scan_path: str = "/scan"
    username: str | None = None
    usergroup: str | None = None
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS

    @classmethod
    def from_env(cls) -> "NullafiConfig":
        """Build config from environment variables, with helpful missing-key errors."""

        missing = [
            name
            for name in ("NULLAFI_API_KEY", "NULLAFI_NAMESPACE", "NULLAFI_BASE_URL")
            if not os.getenv(name)
        ]
        if missing:
            joined = ", ".join(missing)
            raise ValueError(f"Missing required environment variable(s): {joined}")

        timeout_raw = os.getenv("NULLAFI_TIMEOUT_SECONDS")
        timeout_seconds = (
            int(timeout_raw) if timeout_raw else DEFAULT_TIMEOUT_SECONDS
        )

        return cls(
            api_key=os.environ["NULLAFI_API_KEY"],
            namespace=os.environ["NULLAFI_NAMESPACE"],
            base_url=os.environ["NULLAFI_BASE_URL"],
            scan_path=os.getenv("NULLAFI_SCAN_PATH", "/scan"),
            username=os.getenv("NULLAFI_USERNAME"),
            usergroup=os.getenv("NULLAFI_USERGROUP"),
            timeout_seconds=timeout_seconds,
        )


class NullafiClient:
    """HTTP client for the subset of Nullafi needed by the local POC."""

    def __init__(
        self,
        config: NullafiConfig,
        *,
        session: requests.Session | None = None,
    ) -> None:
        self.config = config
        self.session = session or requests.Session()

    def scan(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Send one JSON object to Nullafi and return the JSON response."""

        if not payload:
            return {}

        try:
            response = self.session.post(
                self._scan_url(),
                headers={
                    "Authorization": f"Bearer {self.config.api_key}",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                params=self._query_params(),
                json=payload,
                timeout=self.config.timeout_seconds,
            )
        except requests.Timeout as exc:
            raise NullafiAPIError("Nullafi scan request timed out") from exc
        except requests.RequestException as exc:
            raise NullafiAPIError(f"Nullafi scan request failed: {exc}") from exc

        if response.status_code >= 400:
            raise NullafiAPIError(
                self._error_message(response.status_code, self._safe_json(response)),
                status_code=response.status_code,
                response_body=self._safe_json(response),
            )

        body = self._safe_json(response)
        if not isinstance(body, dict):
            raise NullafiAPIError(
                "Nullafi scan response was not a JSON object",
                status_code=response.status_code,
                response_body=body,
            )

        return body

    def _scan_url(self) -> str:
        base = self.config.base_url.rstrip("/")
        path = self.config.scan_path
        if not path.startswith("/"):
            path = f"/{path}"
        return f"{base}{path}"

    def _query_params(self) -> dict[str, str]:
        params = {"namespace": self.config.namespace}
        if self.config.username:
            params["username"] = self.config.username
        if self.config.usergroup:
            params["usergroup"] = self.config.usergroup
        return params

    @staticmethod
    def _safe_json(response: requests.Response) -> Any:
        try:
            return response.json()
        except ValueError:
            return response.text

    @staticmethod
    def _error_message(status_code: int, body: Any) -> str:
        if isinstance(body, dict) and body.get("message"):
            detail = body["message"]
        else:
            detail = body

        if status_code == 401:
            return f"Nullafi rejected the API key: {detail}"
        if status_code == 403:
            return f"Nullafi API key or namespace is not authorized for scanning: {detail}"
        if status_code == 429:
            return f"Nullafi rate limit exceeded: {detail}"
        if 500 <= status_code:
            return f"Nullafi server error ({status_code}): {detail}"
        return f"Nullafi request failed ({status_code}): {detail}"
