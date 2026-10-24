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
from typing import Any

import httpx
import markdownify as md
from markdown import markdown

from .config import load_config

# upload whitelist for the blog's common media types
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

_MD_EXTENSIONS = ["extra", "sane_lists"]


class WordpressAPIError(RuntimeError):
    """raised when the wordpress api answers with an error."""

    def __init__(self, status: int, code: str, message: str) -> None:
        self.status = status
        self.code = code
        self.message = message
        super().__init__(f"wordpress api {status} [{code}]: {message}")


class WordpressClient:
    def __init__(self) -> None:
        cfg = load_config()
        self._client = httpx.Client(
            base_url=cfg["WP_URL"].rstrip("/") + "/wp-json/wp/v2",
            auth=(cfg["WP_USER"], cfg["WP_APP_PASSWORD"]),
            timeout=float(cfg["WP_TIMEOUT"]),
            verify=cfg["WP_VERIFY_SSL"].lower() == "true",
            headers={"User-Agent": "wordpress-mcp/1.0"},
        )

    # ---- low level ---------------------------------------------------

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        resp = self._client.request(method, path, **kwargs)
        if resp.status_code >= 400:
            self._raise_for(resp)
        return resp.json() if resp.content else None

    def _list_request(self, method: str, path: str, **kwargs: Any) -> tuple[Any, int | None]:
        """like _request, but also returns the x-wp-total header."""
        resp = self._client.request(method, path, **kwargs)
        if resp.status_code >= 400:
            self._raise_for(resp)
        total = resp.headers.get("X-WP-Total")
        data = resp.json() if resp.content else None
        return data, (int(total) if total is not None else None)

    @staticmethod
    def _raise_for(resp: httpx.Response) -> None:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        raise WordpressAPIError(
            resp.status_code,
            body.get("code", "http_error"),
            body.get("message", resp.text[:200]),
        )

    @staticmethod
    def _clean(**kwargs: Any) -> dict[str, Any]:
        """drop none and empty-string values. an empty param would make
        wp ignore the filter and return unfiltered results."""
        return {k: v for k, v in kwargs.items() if v not in (None, "")}

    def close(self) -> None:
        self._client.close()

    # ---- posts -------------------------------------------------------

    def list_posts(
        self, *, status: str = "publish", search: str | None = None,
        category: int | None = None, tag: int | None = None,
        per_page: int = 10, page: int = 1,
        orderby: str = "date", order: str = "desc",
    ) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/posts", params=self._clean(
            status=status, search=search, categories=category, tags=tag,
            per_page=min(per_page, 100), page=page, orderby=orderby, order=order,
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
            posts = self._request("GET", "/posts", params=self._clean(
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
        return self._request("POST", "/posts", json=self._clean(
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
        return self._request("POST", f"/posts/{post_id}", json=self._clean(**fields))

    def delete_post(self, post_id: int, *, trash: bool = True) -> dict:
        return self._request("DELETE", f"/posts/{post_id}", params={"force": not trash})

    # ---- pages -------------------------------------------------------

    def list_pages(
        self, *, status: str = "publish", search: str | None = None,
        per_page: int = 10, page: int = 1,
    ) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/pages", params=self._clean(
            status=status, search=search, per_page=min(per_page, 100), page=page,
        ))

    def get_page(self, id_or_slug: str, *, format_: str = "markdown") -> dict:
        ident = str(id_or_slug)
        if not ident:
            raise WordpressAPIError(400, "empty_ident", "id_or_slug 不能为空")
        if ident.isdigit():
            page = self._request("GET", f"/pages/{ident}", params={"context": "edit"})
        else:
            pages = self._request("GET", "/pages", params=self._clean(
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
        return self._request("POST", f"/pages/{page_id}", json=self._clean(**fields))

    # ---- taxonomy ----------------------------------------------------

    def list_categories(self, *, per_page: int = 100) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/categories", params={
            "per_page": min(per_page, 100), "hide_empty": "false",
        })

    def list_tags(self, *, per_page: int = 100) -> tuple[list[dict], int | None]:
        return self._list_request("GET", "/tags", params={
            "per_page": min(per_page, 100), "hide_empty": "false",
        })

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
        return self._list_request("GET", "/media", params=self._clean(
            per_page=min(per_page, 100), page=page, search=search,
        ))

    def upload_media(
        self, *, filename: str, base64_data: str,
        alt_text: str | None = None, caption: str | None = None,
    ) -> dict:
        ext = ("." + filename.rsplit(".", 1)[-1].lower()) if "." in filename else ""
        mime = _ALLOWED_MEDIA_EXT.get(ext)
        if mime is None:
            raise WordpressAPIError(
                400, "bad_type",
                f"不支持的媒体类型: {ext or '(无扩展名)'}。允许: {', '.join(sorted(_ALLOWED_MEDIA_EXT))}",
            )
        try:
            raw = base64.b64decode(base64_data, validate=True)
        except Exception as exc:  # binascii.error / valueerror
            raise WordpressAPIError(400, "bad_base64", f"base64 解码失败: {exc}") from exc
        if not raw:
            raise WordpressAPIError(400, "empty_data", "媒体数据为空")
        return self._request("POST", "/media", content=raw, headers={
            "Content-Type": mime,
            "Content-Disposition": f'attachment; filename="{filename}"',
        }, params=self._clean(alt_text=alt_text, caption=caption))

    def delete_media(self, media_id: int) -> dict:
        return self._request("DELETE", f"/media/{media_id}", params={"force": True})

    # ---- formatting helpers ------------------------------------------

    @staticmethod
    def md_to_html(markdown_text: str) -> str:
        return markdown(markdown_text, extensions=_MD_EXTENSIONS)

    @staticmethod
    def html_to_md(html_text: str) -> str:
        return md.markdownify(html_text, heading_style="ATX", bullets="-").strip()
