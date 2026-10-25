"""entry point: python -m wordpress_mcp (stdio transport)."""

from .server import client, mcp


def main() -> None:
    try:
        mcp.run()
    finally:
        client.close()


if __name__ == "__main__":
    main()
