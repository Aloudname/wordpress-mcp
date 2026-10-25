"""unit tests for the wordpress rest client. no network or live site."""
from __future__ import annotations

import base64
import json
from typing import Callable

import httpx
import pytest

from wordpress_mcp import wp_client
from wordpress_mcp.config import ConfigError
from wordpress_mcp.wp_client import WordpressAPIError, WordpressClient

_CFG = {
    "WP_URL": "https://127.0.0.1:8443",
    "WP_USER": "mcp_agent",
    "WP_APP_PASSWORD": "abcd efgh",
    "WP_TIMEOUT": "15",
    "WP_VERIFY_SSL": "false",
}
_PNG = base64.b64encode(b"\x89PNG\r\n").decode()


@pytest.fixture
def make_client():
    clients: list[WordpressClient] = []

    def factory(handler: Callable[[httpx.Request], httpx.Response]) -> WordpressClient:
        client = WordpressClient(_CFG, transport=httpx.MockTransport(handler))
        clients.append(client)
        return client

    yield factory
    for client in clients:
        client.close()


def _record(seen: dict):
    def handler(request: httpx.Request) -> httpx.Response:
        seen["request"] = request
        return httpx.Response(200, json={"id": 1})
    return handler


def test_update_post_keeps_empty_strings(make_client) -> None:
    seen: dict = {}
    client = make_client(_record(seen))
    client.update_post(7, content="", excerpt="")

    body = json.loads(seen["request"].content)
    assert body == {"content": "", "excerpt": ""}


def test_query_params_drop_empty_values(make_client) -> None:
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["request"] = request
        return httpx.Response(200, json=[], headers={"X-WP-Total": "0"})

    client = make_client(handler)
    client.list_posts(status="publish", search="", category=None, per_page=5, page=1)

    params = dict(seen["request"].url.params)
    assert "search" not in params
    assert "categories" not in params
    assert params["per_page"] == "5"
    assert params["page"] == "1"


def test_create_post_defaults_to_draft(make_client) -> None:
    seen: dict = {}
    client = make_client(_record(seen))
    client.create_post(title="t", content="c")

    body = json.loads(seen["request"].content)
    assert body["status"] == "draft"
    assert body["content"] == "c"


@pytest.mark.parametrize("exc, code", [
    (httpx.ConnectError("no route"), "unreachable"),
    (httpx.ReadTimeout("slow"), "timeout"),
])
def test_transport_errors_are_structured(make_client, exc, code) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise exc

    client = make_client(handler)
    with pytest.raises(WordpressAPIError) as caught:
        client.get_post("1")
    assert caught.value.code == code
    assert caught.value.status in (503, 504)


def test_non_json_response_is_structured(make_client) -> None:
    client = make_client(lambda request: httpx.Response(
        200, content=b"<html>bad gateway</html>",
        headers={"content-type": "text/html"},
    ))
    with pytest.raises(WordpressAPIError) as caught:
        client.get_post("1")
    assert caught.value.status == 502
    assert caught.value.code == "bad_response"


def test_http_error_body_is_parsed(make_client) -> None:
    client = make_client(lambda request: httpx.Response(
        404, json={"code": "rest_post_invalid_id", "message": "Invalid post ID."},
    ))
    with pytest.raises(WordpressAPIError) as caught:
        client.get_post("99")
    assert caught.value.status == 404
    assert caught.value.code == "rest_post_invalid_id"
    assert caught.value.message == "Invalid post ID."


def test_http_error_without_json_body(make_client) -> None:
    client = make_client(lambda request: httpx.Response(502, text="bad gateway"))
    with pytest.raises(WordpressAPIError) as caught:
        client.get_post("1")
    assert caught.value.code == "http_error"
    assert "bad gateway" in caught.value.message


@pytest.mark.parametrize("per_page", [0, 101, True, "10"])
def test_bad_per_page(make_client, per_page) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.list_posts(per_page=per_page)
    assert caught.value.code == "bad_per_page"


@pytest.mark.parametrize("page", [0, -1, True, "1"])
def test_bad_page(make_client, page) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.list_pages(page=page)
    assert caught.value.code == "bad_page"


def test_taxonomy_pagination(make_client) -> None:
    pages: list[int] = []

    def handler(request: httpx.Request) -> httpx.Response:
        page = int(request.url.params["page"])
        pages.append(page)
        data = [{"id": 1, "name": "a"}, {"id": 2, "name": "b"}]
        if page == 2:
            data = [{"id": 3, "name": "c"}]
        return httpx.Response(200, json=data, headers={"X-WP-Total": "3"})

    client = make_client(handler)
    items, total = client.list_categories(per_page=2)

    assert [item["id"] for item in items] == [1, 2, 3]
    assert total == 3
    assert pages == [1, 2]


def test_resolve_taxonomy_name_and_id(make_client) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json=[{"id": 1, "name": "a"}, {"id": 2, "name": "b"}],
            headers={"X-WP-Total": "2"},
        )

    client = make_client(handler)
    assert client.resolve_category_ids(["b", 1]) == [2, 1]


def test_media_filename_is_sanitized(make_client) -> None:
    seen: dict = {}
    client = make_client(_record(seen))
    client.upload_media(filename="../../evil.png", base64_data=_PNG)

    request = seen["request"]
    assert request.headers["content-disposition"] == 'attachment; filename="evil.png"'
    assert request.headers["content-type"] == "image/png"


def test_media_ascii_fallback_for_unicode_name(make_client) -> None:
    seen: dict = {}
    client = make_client(_record(seen))
    client.upload_media(filename="图片.png", base64_data=_PNG)

    header = seen["request"].headers["content-disposition"]
    header.encode("ascii")  # httpx requires ascii-safe header values
    assert 'filename="upload.png"' in header
    assert "filename*=UTF-8''" in header


def test_media_quote_is_removed(make_client) -> None:
    seen: dict = {}
    client = make_client(_record(seen))
    client.upload_media(filename='ev"il.png', base64_data=_PNG)

    assert seen["request"].headers["content-disposition"] == 'attachment; filename="ev_il.png"'


def test_media_rejects_bad_extension(make_client) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.upload_media(filename="evil.exe", base64_data=_PNG)
    assert caught.value.code == "bad_type"


def test_media_rejects_too_large_payload(make_client) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.upload_media(
            filename="large.png",
            base64_data="A" * (wp_client._MAX_MEDIA_B64 + 4),
        )
    assert caught.value.status == 413
    assert caught.value.code == "too_large"


def test_media_rejects_bad_base64(make_client) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.upload_media(filename="x.png", base64_data="!!!!")
    assert caught.value.code == "bad_base64"


def test_media_rejects_empty_payload(make_client) -> None:
    client = make_client(lambda request: pytest.fail("must not send a request"))
    with pytest.raises(WordpressAPIError) as caught:
        client.upload_media(filename="x.png", base64_data="")
    assert caught.value.code == "empty_data"


def test_client_validates_injected_config() -> None:
    with pytest.raises(ConfigError):
        WordpressClient({**_CFG, "WP_URL": "not-a-url"})
