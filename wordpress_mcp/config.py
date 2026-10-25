"""runtime configuration for the wordpress mcp server.

values are read from a key=value env file in the project root
(``config.env``, mode 0600, never deployed from the dev machine)
and can be overridden by environment variables (``WP_*``).
"""
from __future__ import annotations

import logging
import os
import stat
from pathlib import Path
from urllib.parse import urlparse

PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = PROJECT_ROOT / "config.env"

_REQUIRED = ("WP_URL", "WP_USER", "WP_APP_PASSWORD")
_DEFAULTS = {"WP_TIMEOUT": "15", "WP_VERIFY_SSL": "false"}
_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off"}
_LOOPBACK_HOSTS = {"127.0.0.1", "::1", "localhost"}

log = logging.getLogger("wordpress_mcp.config")


class ConfigError(RuntimeError):
    """raised when configuration is missing or invalid."""


def _warn_if_permissive(path: Path) -> None:
    try:
        mode = path.stat().st_mode
    except OSError:
        return
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        log.warning(
            "%s is readable by group/others (mode %04o); run chmod 600 %s",
            path, stat.S_IMODE(mode), path,
        )


def _read_env_file() -> dict[str, str]:
    if not ENV_FILE.is_file():
        return {}
    _warn_if_permissive(ENV_FILE)
    values: dict[str, str] = {}
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def verify_ssl_enabled(value: str) -> bool:
    return value.strip().lower() in _TRUE


def validate_config(cfg: dict[str, str]) -> None:
    """reject values that would fail later with an opaque error."""
    missing = [key for key in _REQUIRED if not cfg.get(key, "").strip()]
    if missing:
        raise ConfigError(
            f"missing required config: {', '.join(missing)}. "
            f"fill {ENV_FILE} or set the corresponding environment variables."
        )

    raw_url = cfg["WP_URL"].strip()
    if any(char.isspace() for char in raw_url):
        raise ConfigError(f"WP_URL must not contain whitespace: {raw_url!r}")
    parsed = urlparse(raw_url)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ConfigError(f"WP_URL must be an absolute http(s) url: {raw_url!r}")
    if parsed.username or parsed.password:
        raise ConfigError("WP_URL must not embed credentials; use WP_USER/WP_APP_PASSWORD")
    if parsed.query or parsed.fragment:
        raise ConfigError("WP_URL must not contain a query string or fragment")

    raw_timeout = cfg.get("WP_TIMEOUT", _DEFAULTS["WP_TIMEOUT"]).strip()
    try:
        timeout = float(raw_timeout)
    except ValueError as exc:
        raise ConfigError(f"WP_TIMEOUT must be a number, got {raw_timeout!r}") from exc
    if timeout <= 0:
        raise ConfigError(f"WP_TIMEOUT must be greater than 0, got {raw_timeout!r}")

    raw_verify = cfg.get("WP_VERIFY_SSL", _DEFAULTS["WP_VERIFY_SSL"]).strip().lower()
    if raw_verify not in _TRUE | _FALSE:
        raise ConfigError(
            f"WP_VERIFY_SSL must be true/false (or 1/0), got {cfg['WP_VERIFY_SSL']!r}"
        )
    if raw_verify in _FALSE and parsed.hostname not in _LOOPBACK_HOSTS:
        log.warning(
            "WP_VERIFY_SSL=false for non-loopback host %s; traffic is not authenticated",
            parsed.hostname,
        )


def load_config() -> dict[str, str]:
    """merge defaults < env file < environment variables, then validate."""
    merged = {
        **_DEFAULTS,
        **_read_env_file(),
        **{k: v for k, v in os.environ.items() if k.startswith("WP_")},
    }
    validate_config(merged)
    return merged
