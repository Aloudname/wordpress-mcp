"""config parsing and validation, without touching a wordpress site."""
from __future__ import annotations

import logging

import pytest

from wordpress_mcp import config
from wordpress_mcp.config import ConfigError, load_config, validate_config, verify_ssl_enabled

_BASE = {
    "WP_URL": "https://127.0.0.1:8443",
    "WP_USER": "mcp_agent",
    "WP_APP_PASSWORD": "abcd efgh",
    "WP_TIMEOUT": "15",
    "WP_VERIFY_SSL": "false",
}


def _cfg(**overrides: str) -> dict[str, str]:
    return {**_BASE, **overrides}


def test_valid_config() -> None:
    validate_config(_cfg())


@pytest.mark.parametrize("url", [
    "127.0.0.1:8443",
    "ftp://127.0.0.1:8443",
    "https://",
    "https://user:pass@127.0.0.1:8443",
    "https://127.0.0.1:8443/?x=1",
    "https://127.0.0.1:8443/#frag",
    "https://127.0.0.1:8443 /wp-json",
])
def test_bad_url(url: str) -> None:
    with pytest.raises(ConfigError):
        validate_config(_cfg(WP_URL=url))


@pytest.mark.parametrize("timeout", ["0", "-1", "abc", ""])
def test_bad_timeout(timeout: str) -> None:
    with pytest.raises(ConfigError):
        validate_config(_cfg(WP_TIMEOUT=timeout))


@pytest.mark.parametrize("value", ["true", "TRUE", "1", "yes", "on"])
def test_verify_ssl_true(value: str) -> None:
    assert verify_ssl_enabled(value) is True


@pytest.mark.parametrize("value", ["false", "FALSE", "0", "no", "off"])
def test_verify_ssl_false(value: str) -> None:
    assert verify_ssl_enabled(value) is False


def test_bad_verify_ssl() -> None:
    with pytest.raises(ConfigError):
        validate_config(_cfg(WP_VERIFY_SSL="maybe"))


def test_missing_required() -> None:
    with pytest.raises(ConfigError, match="WP_APP_PASSWORD"):
        validate_config(_cfg(WP_APP_PASSWORD=""))


def test_load_config_precedence(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    env_file = tmp_path / "config.env"
    env_file.write_text(
        "WP_URL=https://127.0.0.1:8443\n"
        "WP_USER=file-user\n"
        "WP_APP_PASSWORD=file-pass\n"
        "WP_TIMEOUT=30\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(config, "ENV_FILE", env_file)
    monkeypatch.setenv("WP_USER", "env-user")
    monkeypatch.delenv("WP_URL", raising=False)
    monkeypatch.delenv("WP_APP_PASSWORD", raising=False)
    monkeypatch.delenv("WP_VERIFY_SSL", raising=False)

    merged = load_config()

    assert merged["WP_USER"] == "env-user"
    assert merged["WP_TIMEOUT"] == "30"
    assert merged["WP_VERIFY_SSL"] == "false"


def test_permissive_env_file_warns(
    monkeypatch: pytest.MonkeyPatch, tmp_path, caplog: pytest.LogCaptureFixture,
) -> None:
    env_file = tmp_path / "config.env"
    env_file.write_text("WP_URL=https://127.0.0.1:8443\n", encoding="utf-8")
    env_file.chmod(0o644)
    monkeypatch.setattr(config, "ENV_FILE", env_file)

    with caplog.at_level(logging.WARNING, logger="wordpress_mcp.config"):
        assert config._read_env_file()["WP_URL"] == "https://127.0.0.1:8443"

    assert "readable by group/others" in caplog.text
