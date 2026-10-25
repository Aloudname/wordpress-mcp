"""typed http client for the wordpress rest api (wp/v2).

the client exposes only the subset of the rest api used by the mcp
tools, with structured errors and explicit pagination. requests run
over the pi's loopback interface using an application password.

note: uses a synchronous httpx client. local requests take
milliseconds, and fastmcp runs sync tools in a worker thread, so this
does not block the event loop at this scale.
"""
from __future__ import annotations

import base64
import binascii
import os
import re
from typing import Any
from urllib.parse import quote

import httpx
import markdownify as md
from markdown import markdown

from .config import load_config, validate_config, verify_ssl_enabled

# upload whitelist for the blog's common media types. svg is allowed by
# this client, but wordpress core usually rejects it; sites that enable
# svg uploads should treat uploaded svg files as untrusted html.
_ALLOWED_MEDIA_EXT = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".avif": "image/avif",
    ".mp4": "video/mp4",
    ".mp3": "audio/mpeg",
    ".pdf": "application/pdf",
}

# keep the encoded request below nginx's default 50m body limit
_MAX_MEDIA_BYTES = 32 * 1024 * 1024
_MAX_MEDIA_B64 = ((_MAX_MEDIA_BYTES + 2) // 3) * 4

_FILENAME_BAD = re.compile(r'[\x00-\x1f\x7f"\\/;]')
_FILENAME_ASCII = re.compile(r"[^A-Za-z0-9._ -]")

_MD_EXTENSIONS = ["extra", "sane_lists"]


class WordpressAPIError(RuntimeError):
    """raised when the wordpress api answers with an error."""

    def __init__(self, status: int, code: str, message: str) -> None:
        self.status = status
        self.code = code
        self.message = message
        super().__init__(f"wordpress api {status} [{code}]: {message}")


class WordpressClient:
    def __init__(
        self,
        config: dict[str, str] | None = None,
        *,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        cfg = dict(config) if config is not None else load_config()
        validate_config(cfg)
        self._client = httpx.Client(
            base_url=cfg["WP_URL"].strip().rstrip("/") + "/wp-json/wp/v2",
            auth=(cfg["WP_USER"], cfg["WP_APP_PASSWORD"]),
            timeout=float(cfg.get("WP_TIMEOUT", "15")),
            verify=verify_ssl_enabled(cfg.get("WP_VERIFY_SSL", "false")),
            headers={"User-Agent": "wordpress-mcp/1.0"},
            # the api is local; ignore proxy env vars and avoid leaking
            # credentials to an unintended proxy
            trust_env=False,
            transport=transport,
        )

    # ---- low level ---------------------------------------------------

    def _send(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            return self._client.request(method, path, **kwargs)
        except httpx.TimeoutException as exc:
            raise WordpressAPIError(
                504, "timeout", f"WordPress API 请求超时: {exc}"
            ) from exc
        except httpx.RequestError as exc:
            raise WordpressAPIError(
                503, "unreachable", f"WordPress API 不可达: {exc}"
            ) from exc

    @staticmethod
    def _json(resp: httpx.Response) -> Any:
        if not resp.content:
            return None
        try:
            return resp.json()
        except ValueError as exc:
            content_type = resp.headers.get("content-type", "unknown")
            raise WordpressAPIError(
                502,
                "bad_response",
                f"WordPress 返回非 JSON 响应 (HTTP {resp.status_code}, "
                f"content-type={content_type})",
            ) from exc

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        resp = self._send(method, path, **kwargs)
        if resp.status_code >= 400:
            self._raise_for(resp)
        return self._json(resp)

    def _list_request(self, method: str, path: str, **kwargs: Any) -> tuple[Any, int | None]:
        """like _request, but also returns the x-wp-total header."""
        resp = self._send(method, path, **kwargs)
        if resp.status_code >= 400:
            self._raise_for(resp)
        total = resp.headers.get("X-WP-Total")
        data = self._json(resp)
        if data is not None and not isinstance(data, list):
            raise WordpressAPIError(
                502, "bad_response",
                "WordPress 列表接口返回了非数组响应",
            )
        try:
            total_int = int(total) if total is not None else None
        except ValueError:
            total_int = None
        return data, total_int

    @staticmethod
    def _raise_for(resp: httpx.Response) -> None:
        try:
            body = resp.json()
        except ValueError:
            body = None
        if not isinstance(body, dict):
            body = {}
        code = body.get("code", "http_error")
        message = body.get("message") or resp.text[:200] or f"HTTP {resp.status_code}"
        raise WordpressAPIError(resp.status_code, str(code), str(message))

    @staticmethod
    def _params(**kwargs: Any) -> dict[str, Any]:
        """drop none and empty-string values from query parameters. an
        empty param would make wp ignore the filter and return unfiltered
        results."""
        return {k: v for k, v in kwargs.items() if v not in (None, "")}

    @staticmethod
    def _body(**kwargs: Any) -> dict[str, Any]:
        """drop only none values from a json body. an empty string is a
        valid value here: it clears content/excerpt instead of being
        silently ignored by wordpress."""
        return {k: v for k, v in kwargs.items() if v is not None}

    @staticmethod
    def _page_size(per_page: int) -> int:
        if isinstance(per_page, bool) or not isinstance(per_page, int) \
                or not 1 <= per_page <= 100:
            raise WordpressAPIError(400, "bad_per_page", "per_page 必须是 1-100 的整数")
        return per_page

    @staticmethod
    def _page_number(page: int) -> int:
        if isinstance(page, bool) or not isinstance(page, int) or page < 1:
            raise WordpressAPIError(400, "bad_page", "page 必须是大于等于 1 的整数")
        return page

    def close(self) -> None:
        self._client.close()

    # ---- posts -------------------------------------------------------

    def list_posts(
        self, *, status: str = "publish", search: str | None = None,
        category: int | None = None, tag: int | None = None,
        per_page: int = 10, page: int = 1,
        orderby: str = "date", order: str = "desc",
    ) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/posts", params=self._params(
            status=status, search=search, categories=category, tags=tag,
            per_page=self._page_size(per_page), page=self._page_number(page),
            orderby=orderby, order=order,
        ))

    def get_post(self, id_or_slug: str, *, format_: str = "markdown") -> dict:
        """format_: 'markdown' (converted from rendered html) or 'html' (raw stored content).

        slug lookup only works for published posts: wordpress does not
        generate slugs for drafts, use the id for drafts.
        """
        ident = str(id_or_slug)
        if not ident:
            raise WordpressAPIError(400, "empty_ident", "id_or_slug 不能为空")
        if ident.isdigit():
            post = self._request("GET", f"/posts/{ident}", params={"context": "edit"})
        else:
            # the rest list endpoint defaults to status=publish, so slug
            # lookup must pass status=any to cover drafts
            posts = self._request("GET", "/posts", params=self._params(
                slug=ident, context="edit", status="any"))
            if not posts:
                raise WordpressAPIError(404, "not_found", f"没有 slug 为 {ident!r} 的文章")
            post = posts[0]
        if format_ == "markdown":
            post["content"] = self.html_to_md(post["content"]["rendered"])
        elif format_ == "html":
            post["content"] = post["content"]["raw"]
        else:
            raise WordpressAPIError(400, "bad_format", "format 仅支持 markdown 或 html")
        return post

    def create_post(
        self, *, title: str, content: str, excerpt: str | None = None,
        status: str = "draft", categories: list[int] | None = None,
        tags: list[int] | None = None, slug: str | None = None,
    ) -> dict:
        if status not in ("draft", "publish", "private", "pending"):
            raise WordpressAPIError(400, "bad_status", f"不支持的 status: {status!r}")
        return self._request("POST", "/posts", json=self._body(
            title=title, content=content, excerpt=excerpt, status=status,
            categories=categories, tags=tags, slug=slug,
        ))

    def update_post(self, post_id: int, **fields: Any) -> dict:
        allowed = {"title", "content", "excerpt", "status", "categories", "tags", "slug"}
        unknown = set(fields) - allowed
        if unknown:
            raise WordpressAPIError(400, "bad_field", f"不支持的文章字段: {sorted(unknown)}")
        if "status" in fields and fields["status"] not in ("draft", "publish", "private", "pending"):
            raise WordpressAPIError(400, "bad_status", f"不支持的 status: {fields['status']!r}")
        return self._request("POST", f"/posts/{post_id}", json=self._body(**fields))

    def delete_post(self, post_id: int, *, trash: bool = True) -> dict:
        return self._request("DELETE", f"/posts/{post_id}", params={"force": not trash})

    # ---- pages -------------------------------------------------------

    def list_pages(
        self, *, status: str = "publish", search: str | None = None,
        per_page: int = 10, page: int = 1,
    ) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/pages", params=self._params(
            status=status, search=search,
            per_page=self._page_size(per_page), page=self._page_number(page),
        ))

    def get_page(self, id_or_slug: str, *, format_: str = "markdown") -> dict:
        ident = str(id_or_slug)
        if not ident:
            raise WordpressAPIError(400, "empty_ident", "id_or_slug 不能为空")
        if ident.isdigit():
            page = self._request("GET", f"/pages/{ident}", params={"context": "edit"})
        else:
            pages = self._request("GET", "/pages", params=self._params(
                slug=ident, context="edit", status="any"))
            if not pages:
                raise WordpressAPIError(404, "not_found", f"没有 slug 为 {ident!r} 的页面")
            page = pages[0]
        if format_ == "markdown":
            page["content"] = self.html_to_md(page["content"]["rendered"])
        elif format_ == "html":
            page["content"] = page["content"]["raw"]
        else:
            raise WordpressAPIError(400, "bad_format", "format 仅支持 markdown 或 html")
        return page

    def update_page(self, page_id: int, **fields: Any) -> dict:
        allowed = {"title", "content", "excerpt", "status"}
        unknown = set(fields) - allowed
        if unknown:
            raise WordpressAPIError(400, "bad_field", f"不支持的页面字段: {sorted(unknown)}")
        if "status" in fields and fields["status"] not in ("draft", "publish", "private", "pending"):
            raise WordpressAPIError(400, "bad_status", f"不支持的 status: {fields['status']!r}")
        return self._request("POST", f"/pages/{page_id}", json=self._body(**fields))

    # ---- taxonomy ----------------------------------------------------

    def _list_all(self, path: str, *, per_page: int = 100) -> tuple[list[dict], int | None]:
        """fetch every page. the rest api caps per_page at 100, so sites
        with more categories/tags need this loop for name resolution."""
        size = self._page_size(per_page)
        items: list[dict] = []
        total: int | None = None
        page = 1
        while True:
            data, page_total = self._list_request("GET", path, params={
                "per_page": size, "page": page, "hide_empty": "false",
            })
            if total is None:
                total = page_total
            data = data or []
            items.extend(data)
            # no total header: stop after one page rather than loop forever
            if not data or total is None or len(items) >= total:
                break
            page += 1
        return items, total

    def list_categories(self, *, per_page: int = 100) -> tuple[list[dict], int | None]:
        return self._list_all("/categories", per_page=per_page)

    def list_tags(self, *, per_page: int = 100) -> tuple[list[dict], int | None]:
        return self._list_all("/tags", per_page=per_page)

    def resolve_category_ids(self, items: list[int | str]) -> list[int]:
        categories, _ = self.list_categories()
        return self._resolve_tax(items, categories, "分类")

    def resolve_tag_ids(self, items: list[int | str]) -> list[int]:
        tags, _ = self.list_tags()
        return self._resolve_tax(items, tags, "标签")

    @staticmethod
    def _resolve_tax(items: list[int | str], taxonomy: list[dict], label: str) -> list[int]:
        by_id = {t["id"]: t for t in taxonomy}
        by_name = {t["name"]: t for t in taxonomy}
        resolved: list[int] = []
        for item in items:
            hit = by_id.get(item)
            if hit is None and str(item).isdigit():
                hit = by_id.get(int(item))
            if hit is None:
                hit = by_name.get(item)
            if hit is None:
                raise WordpressAPIError(404, "not_found", f"{label}不存在: {item!r}")
            resolved.append(hit["id"])
        return resolved

    # ---- media -------------------------------------------------------

    def list_media(
        self, *, per_page: int = 10, page: int = 1, search: str | None = None,
    ) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/media", params=self._params(
            per_page=self._page_size(per_page), page=self._page_number(page),
            search=search,
        ))

    @staticmethod
    def _safe_filename(filename: str) -> str:
        if not isinstance(filename, str):
            raise WordpressAPIError(400, "bad_filename", "filename 必须是字符串")
        name = os.path.basename(filename.strip().replace("\\", "/"))
        name = _FILENAME_BAD.sub("_", name).strip()
        if not name or name in (".", ".."):
            raise WordpressAPIError(400, "bad_filename", "filename 不能为空")
        if len(name.encode("utf-8")) > 200:
            raise WordpressAPIError(400, "bad_filename", "filename 过长(最多 200 字节)")
        return name

    @staticmethod
    def _content_disposition(name: str) -> str:
        stem, ext = os.path.splitext(name)
        ascii_stem = _FILENAME_ASCII.sub("_", stem).strip(" ._") or "upload"
        ascii_name = ascii_stem + ext
        if name == ascii_name:
            return f'attachment; filename="{name}"'
        return (
            f'attachment; filename="{ascii_name}"; '
            f"filename*=UTF-8''{quote(name, safe='')}"
        )

    def upload_media(
        self, *, filename: str, base64_data: str,
        alt_text: str | None = None, caption: str | None = None,
    ) -> dict:
        name = self._safe_filename(filename)
        ext = os.path.splitext(name)[1].lower()
        mime = _ALLOWED_MEDIA_EXT.get(ext)
        if mime is None:
            raise WordpressAPIError(
                400, "bad_type",
                f"不支持的媒体类型: {ext or '(无扩展名)'}。允许: {', '.join(sorted(_ALLOWED_MEDIA_EXT))}",
            )
        if not isinstance(base64_data, str):
            raise WordpressAPIError(400, "bad_base64", "base64_data 必须是字符串")
        encoded = "".join(base64_data.split())
        if len(encoded) > _MAX_MEDIA_B64:
            raise WordpressAPIError(
                413, "too_large",
                f"媒体文件超过 {_MAX_MEDIA_BYTES // (1024 * 1024)} MiB 上限",
            )
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise WordpressAPIError(400, "bad_base64", f"base64 解码失败: {exc}") from exc
        if not raw:
            raise WordpressAPIError(400, "empty_data", "媒体数据为空")
        if len(raw) > _MAX_MEDIA_BYTES:
            raise WordpressAPIError(
                413, "too_large",
                f"媒体文件超过 {_MAX_MEDIA_BYTES // (1024 * 1024)} MiB 上限",
            )
        return self._request("POST", "/media", content=raw, headers={
            "Content-Type": mime,
            "Content-Disposition": self._content_disposition(name),
        }, params=self._params(alt_text=alt_text, caption=caption))

    def delete_media(self, media_id: int) -> dict:
        return self._request("DELETE", f"/media/{media_id}", params={"force": True})

    # ---- formatting helpers ------------------------------------------

    @staticmethod
    def md_to_html(markdown_text: str) -> str:
        return markdown(markdown_text, extensions=_MD_EXTENSIONS)

    @staticmethod
    def html_to_md(html_text: str) -> str:
        return md.markdownify(html_text, heading_style="ATX", bullets="-").strip()
