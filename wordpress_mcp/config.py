"""Runtime configuration for the WordPress MCP server.

Values are read from a KEY=VALUE env file in the project root
(``config.env``, mode 0600, never deployed from the dev machine)
and can be overridden by environment variables (``WP_*``).
"""
from __future__ import annotations

import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / "config.env"

_REQUIRED = ("WP_URL", "WP_USER", "WP_APP_PASSWORD")
_DEFAULTS = {"WP_TIMEOUT": "15", "WP_VERIFY_SSL": "false"}


class ConfigError(RuntimeError):
    """Raised when required configuration is missing."""


def _read_env_file() -> dict[str, str]:
    if not ENV_FILE.is_file():
        return {}
    values: dict[str, str] = {}
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def load_config() -> dict[str, str]:
    """Merge defaults < env file < environment variables."""
    merged = {
        **_DEFAULTS,
        **_read_env_file(),
        **{k: v for k, v in os.environ.items() if k.startswith("WP_")},
    }
    missing = [key for key in _REQUIRED if key not in merged]
    if missing:
        raise ConfigError(
            f"missing required config: {', '.join(missing)}. "
            f"Fill {ENV_FILE} or set the corresponding environment variables."
        )
    return merged
