"""full mcp stdio protocol test: spawns the real server and drives it
with the official sdk client (initialize -> list_tools -> call_tool).
"""
from __future__ import annotations

import asyncio
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

EXPECTED_TOOLS = {
    "wp_list_posts", "wp_get_post", "wp_create_post", "wp_update_post",
    "wp_delete_post", "wp_list_pages", "wp_get_page", "wp_update_page",
    "wp_list_categories", "wp_list_tags", "wp_list_media", "wp_upload_media",
    "markdown_to_html", "html_to_markdown",
}


async def run() -> int:
    params = StdioServerParameters(
        command=str(ROOT / "venv" / "bin" / "python"),
        args=["-m", "wordpress_mcp"],
        cwd=str(ROOT),
    )
    async with stdio_client(params) as (read, write), ClientSession(read, write) as session:
        init = await session.initialize()
        assert init.server_info.name == "wordpress-blog", init.server_info
        print(f"[ok] initialize (server={init.server_info.name} "
              f"protocol={init.protocol_version})")

        tools = await session.list_tools()
        by_name = {t.name: t for t in tools.tools}
        missing = EXPECTED_TOOLS - set(by_name)
        assert not missing, f"缺少工具: {sorted(missing)}"
        assert by_name["wp_list_posts"].annotations.readOnlyHint is True
        assert by_name["wp_delete_post"].annotations.destructiveHint is True
        print(f"[ok] list_tools: {len(by_name)} 个工具齐全(含安全注解)")

        result = await session.call_tool("wp_list_posts", {"status": "any", "per_page": 1})
        assert not result.is_error, result.content
        print("[ok] call_tool wp_list_posts")

        result = await session.call_tool("markdown_to_html", {"markdown_text": "# 你好\n\n**世界**"})
        assert not result.is_error and "世界" in str(result.content)
        print("[ok] call_tool markdown_to_html")

        prompts = await session.list_prompts()
        names = {p.name for p in prompts.prompts}
        assert "blog_writing_guide" in names, names
        print(f"[ok] list_prompts: {sorted(names)}")

    print("HANDSHAKE TEST PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(run()))
