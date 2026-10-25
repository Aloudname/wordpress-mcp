"""live smoke tests against the real wordpress site.

non-destructive: creates one draft post, updates it, then trashes and
permanently removes it; uploads one tiny png and removes it. nothing is
ever published.
"""
from __future__ import annotations

import base64
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from wordpress_mcp.wp_client import WordpressClient  # noqa: E402

# 1x1 transparent png
_PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)

_PASSED = 0


def check(label: str, condition: bool, detail: str = "") -> None:
    global _PASSED
    if not condition:
        print(f"[FAIL] {label} {detail}")
        raise SystemExit(1)
    _PASSED += 1
    print(f"[ok] {label}")


def main() -> int:
    c = WordpressClient()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    pid = None
    media_id = None
    try:
        # 0. remove leftovers from previous runs (any status)
        leftovers, _ = c.list_posts(status="any", search="__mcp_smoke_", per_page=100)
        for p in leftovers:
            c.delete_post(p["id"], trash=False)
        if leftovers:
            print(f"[ok] 清理历史残留 {len(leftovers)} 篇")

        # 1. read-only listings
        cats, ctotal = c.list_categories()
        tags, ttotal = c.list_tags()
        media, mtotal = c.list_media(per_page=1)
        check("list_categories/list_tags/list_media",
              isinstance(cats, list) and isinstance(tags, list) and isinstance(media, list),
              f"categories={ctotal} tags={ttotal} media={mtotal}")

        # 2. markdown <-> html roundtrip
        html = c.md_to_html("# 测试标题\n\n**加粗** 和 *斜体*\n\n- 列表项")
        md = c.html_to_md(html)
        check("markdown <-> html roundtrip",
              "测试标题" in md and "加粗" in md, repr(md[:80]))

        # 3. draft lifecycle: create -> update -> read by id/slug -> trash -> purge
        # wp does not generate slugs for drafts, so pass an explicit slug
        slug = f"__mcp_smoke_{stamp}"
        post = c.create_post(title=slug, content=html, status="draft", slug=slug)
        pid = post["id"]
        check("create_post 返回 draft", post["status"] == "draft", f"id={pid}")

        updated = c.update_post(pid, content=c.md_to_html("**更新后的内容**"))
        check("update_post 生效", "更新后的内容" in updated["content"]["raw"])

        got_md = c.get_post(str(pid), format_="markdown")
        got_html = c.get_post(str(pid), format_="html")
        check("get_post 按 id 读取(markdown/html)",
              "更新后的内容" in got_md["content"] and "更新后的内容" in got_html["content"])

        got_slug = c.get_post(post["slug"], format_="html")
        check("get_post 按 slug 读取", got_slug["id"] == pid)

        trashed = c.delete_post(pid, trash=True)
        check("delete_post 移入回收站", trashed["status"] == "trash")
        c.delete_post(pid, trash=False)  # purge test residue
        pid = None

        # 4. media upload -> delete
        item = c.upload_media(filename=f"smoke-{stamp}.png",
                              base64_data=base64.b64encode(_PNG_1PX).decode(),
                              alt_text="smoke test image")
        media_id = item["id"]
        check("upload_media", media_id > 0 and "source_url" in item, item.get("source_url", ""))
        c.delete_media(media_id)
        media_id = None

        # 5. category name/id resolution
        name = cats[0]["name"]
        ids = c.resolve_category_ids([name, cats[0]["id"]])
        check("resolve_category_ids 名称+ID", len(ids) == 2 and ids[0] == ids[1], repr(name))

        print(f"\nALL {_PASSED} CHECKS PASSED")
        return 0
    finally:
        # never leave drafts/media behind when a check fails mid-test
        if media_id is not None:
            try:
                c.delete_media(media_id)
            except Exception:
                pass
        if pid is not None:
            try:
                c.delete_post(pid, trash=False)
            except Exception:
                pass
        c.close()


if __name__ == "__main__":
    sys.exit(main())
