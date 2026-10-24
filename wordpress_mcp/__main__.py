"""Entry point: python -m wordpress_mcp (stdio transport)."""

from .server import mcp


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
