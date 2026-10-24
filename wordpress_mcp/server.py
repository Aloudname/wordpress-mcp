"""mcp server exposing wordpress blog editing tools (stdio transport).

tool naming: all wordpress tools are prefixed with ``wp_`` to avoid
collisions with other mcp servers in the same agent session.

safety design:
- new posts default to draft, publish after review
- delete defaults to trash, permanent delete needs explicit trash=false
- the server uses the dedicated mcp_agent user (editor role), least privilege
"""
from __future__ import annotations

import logging
import sys

from mcp.server.mcpserver import MCPServer

from .wp_client import WordpressAPIError, WordpressClient

logging.basicConfig(
    stream=sys.stderr,
    level=logging.WARNING,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("wordpress_mcp")

mcp = MCPServer(
    "wordpress-blog",
    instructions=(
        "WordPress 博客管理工具(aloudname.top)。"
        "写作流程:先用 markdown 起草,再 markdown_to_html 转换排版,"
        "用 wp_create_post 以 draft 状态创建,人工审阅后改为 publish。"
        "修改文章前先 wp_get_post 读取现状。删除默认进回收站。"
    ),
)

client = WordpressClient()  # validate config at startup, fail fast


# ---- helpers ----------------------------------------------------------


def _plain(value: object) -> str | None:
    """Extract plain text from a WP {rendered/raw/protected} object."""
    if isinstance(value, dict):
        return str(value.get("rendered") or value.get("raw") or "")
    return str(value) if value is not None else None


def _post_summary(post: dict) -> dict:
    return {
        "id": post["id"],
        "date": post.get("date"),
        "modified": post.get("modified"),
        "title": _plain(post.get("title")),
        "slug": post.get("slug"),
        "status": post.get("status"),
        "link": post.get("link"),
    }


def _tax_names(ids: list[int], kind: str) -> list[dict]:
    if not ids:
        return []
    items, _ = client.list_categories() if kind == "category" else client.list_tags()
    lookup = {t["id"]: t for t in items}
    return [
        {"id": i, "name": lookup[i]["name"], "slug": lookup[i].get("slug")}
        for i in ids if i in lookup
    ]


def _post_detail(post: dict) -> dict:
    content = post.get("content")
    if isinstance(content, dict):
        content = content.get("raw")
    out = {
        "id": post["id"],
        "date": post.get("date"),
        "modified": post.get("modified"),
        "title": _plain(post.get("title")),
        "slug": post.get("slug"),
        "status": post.get("status"),
        "link": post.get("link"),
        "excerpt": _plain(post.get("excerpt")),
        "content": content,
    }
    if "categories" in post:
        out["categories"] = _tax_names(post["categories"], "category")
    if "tags" in post:
        out["tags"] = _tax_names(post["tags"], "tag")
    return out


# ---- posts ------------------------------------------------------------


@mcp.tool()
def wp_list_posts(
    status: str = "publish", search: str | None = None,
    category: str | None = None, tag: str | None = None,
    per_page: int = 10, page: int = 1,
    orderby: str = "date", order: str = "desc",
) -> dict:
    """列出博客文章(支持按状态/关键词/分类/标签过滤与分页)。

    Args:
        status: 状态过滤:draft/publish/private/pending,或 "any" 查全部
        search: 标题与内容关键词搜索
        category: 分类名或分类 ID
        tag: 标签名或标签 ID
        per_page: 每页条数(最大 100)
        page: 页码(从 1 开始)
        orderby: 排序字段(date/title/modified)
        order: asc 或 desc
    """
    cat_id = client.resolve_category_ids([category])[0] if category else None
    tag_id = client.resolve_tag_ids([tag])[0] if tag else None
    data, total = client.list_posts(
        status=status, search=search, category=cat_id, tag=tag_id,
        per_page=per_page, page=page, orderby=orderby, order=order,
    )
    return {"total": total, "page": page, "items": [_post_summary(p) for p in data]}


@mcp.tool()
def wp_get_post(id_or_slug: str, format_: str = "markdown") -> dict:
    """读取单篇文章全文。

    Args:
        id_or_slug: 文章 ID,或 slug(文章网址最后一段)。注意:草稿没有 slug(WordPress 发布时才生成),草稿请用 ID 查询
        format_: markdown(渲染后的 HTML 转为 markdown,适合阅读与编辑)或 html(原始存储内容)
    """
    return _post_detail(client.get_post(id_or_slug, format_=format_))


@mcp.tool()
def wp_create_post(
    title: str, content: str, excerpt: str | None = None,
    status: str = "draft",
    categories: list[str] | None = None,
    tags: list[str] | None = None,
    slug: str | None = None,
) -> dict:
    """创建新文章(默认保存为草稿)。

    Args:
        title: 文章标题
        content: 正文 HTML(建议先用 markdown_to_html 完成排版)
        excerpt: 摘要,可省略
        status: draft(默认)/publish/private/pending
        categories: 分类名或 ID 列表,如 ["技术", "随笔"]
        tags: 标签名或 ID 列表
        slug: 自定义固定链接,可省略(自动按标题生成)
    """
    cat_ids = client.resolve_category_ids(categories) if categories else None
    tag_ids = client.resolve_tag_ids(tags) if tags else None
    post = client.create_post(
        title=title, content=content, excerpt=excerpt, status=status,
        categories=cat_ids, tags=tag_ids, slug=slug,
    )
    return _post_detail(post)


@mcp.tool()
def wp_update_post(
    post_id: int, title: str | None = None, content: str | None = None,
    excerpt: str | None = None, status: str | None = None,
    categories: list[str] | None = None, tags: list[str] | None = None,
) -> dict:
    """更新文章。只传需要修改的字段,未传字段保持不变。

    Args:
        post_id: 文章 ID
        title: 新标题
        content: 新正文 HTML
        excerpt: 新摘要
        status: 新状态(draft/publish/private/pending)
        categories: 新分类列表(覆盖式设置)
        tags: 新标签列表(覆盖式设置)
    """
    fields: dict = {}
    if title is not None:
        fields["title"] = title
    if content is not None:
        fields["content"] = content
    if excerpt is not None:
        fields["excerpt"] = excerpt
    if status is not None:
        fields["status"] = status
    if categories is not None:
        fields["categories"] = client.resolve_category_ids(categories)
    if tags is not None:
        fields["tags"] = client.resolve_tag_ids(tags)
    if not fields:
        raise WordpressAPIError(400, "empty_update", "没有提供任何要修改的字段")
    return _post_detail(client.update_post(post_id, **fields))


@mcp.tool()
def wp_delete_post(post_id: int, trash: bool = True) -> dict:
    """删除文章。默认移入回收站(后台可恢复);永久删除需显式 trash=false。

    Args:
        post_id: 文章 ID
        trash: true=移入回收站(默认),false=永久删除(不可恢复,慎用)
    """
    result = client.delete_post(post_id, trash=trash)
    return {"deleted": True, "trashed": trash, "post": _post_summary(result)}


# ---- pages ------------------------------------------------------------


@mcp.tool()
def wp_list_pages(status: str = "publish", search: str | None = None,
                  per_page: int = 10, page: int = 1) -> dict:
    """列出独立页面(如「关于」「友链」)。

    Args:
        status: 状态过滤:publish/draft/private/pending,或 "any"
        search: 标题与内容关键词搜索
        per_page: 每页条数(最大 100)
        page: 页码(从 1 开始)
    """
    data, total = client.list_pages(status=status, search=search, per_page=per_page, page=page)
    return {"total": total, "page": page, "items": [_post_summary(p) for p in data]}


@mcp.tool()
def wp_get_page(id_or_slug: str, format_: str = "markdown") -> dict:
    """读取单个页面的内容。

    Args:
        id_or_slug: 页面 ID 或 slug
        format_: markdown 或 html
    """
    return _post_detail(client.get_page(id_or_slug, format_=format_))


@mcp.tool()
def wp_update_page(
    page_id: int, title: str | None = None, content: str | None = None,
    excerpt: str | None = None, status: str | None = None,
) -> dict:
    """更新页面。只传需要修改的字段。

    Args:
        page_id: 页面 ID
        title: 新标题
        content: 新正文 HTML
        excerpt: 新摘要
        status: 新状态(draft/publish/private/pending)
    """
    fields: dict = {}
    if title is not None:
        fields["title"] = title
    if content is not None:
        fields["content"] = content
    if excerpt is not None:
        fields["excerpt"] = excerpt
    if status is not None:
        fields["status"] = status
    if not fields:
        raise WordpressAPIError(400, "empty_update", "没有提供任何要修改的字段")
    return _post_detail(client.update_page(page_id, **fields))


# ---- taxonomy & media -------------------------------------------------


@mcp.tool()
def wp_list_categories() -> dict:
    """列出全部分类(id/名称/slug/文章数),创建文章时用于选择分类。"""
    data, total = client.list_categories()
    return {"total": total, "items": [
        {"id": c["id"], "name": c["name"], "slug": c.get("slug"), "count": c.get("count")}
        for c in data
    ]}


@mcp.tool()
def wp_list_tags() -> dict:
    """列出全部标签(id/名称/slug/文章数)。"""
    data, total = client.list_tags()
    return {"total": total, "items": [
        {"id": t["id"], "name": t["name"], "slug": t.get("slug"), "count": t.get("count")}
        for t in data
    ]}


@mcp.tool()
def wp_list_media(per_page: int = 10, page: int = 1, search: str | None = None) -> dict:
    """列出媒体库中的文件(图片/视频等)。

    Args:
        per_page: 每页条数(最大 100)
        page: 页码(从 1 开始)
        search: 按文件名关键词搜索
    """
    data, total = client.list_media(per_page=per_page, page=page, search=search)
    return {"total": total, "page": page, "items": [
        {
            "id": m["id"], "title": _plain(m.get("title")),
            "source_url": m.get("source_url"), "mime_type": m.get("mime_type"),
            "alt_text": m.get("alt_text"),
        }
        for m in data
    ]}


@mcp.tool()
def wp_upload_media(
    filename: str, base64_data: str,
    alt_text: str | None = None, caption: str | None = None,
) -> dict:
    """上传图片/文件到媒体库(内容以 base64 传入)。上传后可把返回的 source_url 插入文章。

    Args:
        filename: 文件名(含扩展名),支持 png/jpg/jpeg/gif/webp/svg/avif/mp4/mp3/pdf
        base64_data: 文件内容的 base64 编码(大图建议先压缩)
        alt_text: 无障碍替代文本
        caption: 图注
    """
    media = client.upload_media(filename=filename, base64_data=base64_data,
                                alt_text=alt_text, caption=caption)
    return {
        "id": media["id"], "title": _plain(media.get("title")),
        "source_url": media.get("source_url"), "mime_type": media.get("mime_type"),
        "alt_text": media.get("alt_text"),
    }


# ---- formatting helpers -----------------------------------------------


@mcp.tool()
def markdown_to_html(markdown_text: str) -> dict:
    """把 Markdown 排版转换为 WordPress 正文 HTML(含表格/代码块/有序列表扩展)。"""
    return {"html": client.md_to_html(markdown_text)}


@mcp.tool()
def html_to_markdown(html_text: str) -> dict:
    """把 HTML 转换为 Markdown(阅读与草稿编辑用,注意:转换有损,回写前请核对)。"""
    return {"markdown": client.html_to_md(html_text)}


# ---- prompt -----------------------------------------------------------


@mcp.prompt()
def blog_writing_guide() -> str:
    """博客写作与排版约定"""
    return """写作与排版约定:
1. 先用 Markdown 起草正文,再用 markdown_to_html 转换排版后提交给 wp_create_post / wp_update_post
2. 创建文章一律先用 draft 状态,人工审阅后再改为 publish
3. 修改文章前先 wp_get_post 读取当前内容,避免覆盖他人编辑
4. 删除一律先移入回收站(trash=true),不要直接永久删除
5. 分类用 wp_list_categories 查现有分类名,不新建分类(新建需后台操作)
6. 图片先压缩再通过 wp_upload_media 上传,把 source_url 插入正文
7. 排版要点:段落间空行、标题层级从 h2 起(文章标题已是 h1)、代码用围栏块、中英文之间加空格"""
