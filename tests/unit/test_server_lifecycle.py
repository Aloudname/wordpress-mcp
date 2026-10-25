"""the stdio process must close its http client on every exit path."""
from __future__ import annotations


def test_main_closes_client(monkeypatch) -> None:
    monkeypatch.setenv("WP_URL", "https://127.0.0.1:8443")
    monkeypatch.setenv("WP_USER", "mcp_agent")
    monkeypatch.setenv("WP_APP_PASSWORD", "abcd efgh")
    monkeypatch.setenv("WP_TIMEOUT", "15")
    monkeypatch.setenv("WP_VERIFY_SSL", "false")

    from wordpress_mcp import __main__ as entry
    from wordpress_mcp import server

    closed: list[bool] = []
    monkeypatch.setattr(server.mcp, "run", lambda: None)
    monkeypatch.setattr(server.client, "close", lambda: closed.append(True))

    entry.main()

    assert closed == [True]
