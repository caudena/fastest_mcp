"""Pinned real FastMCP peer; stdout is reserved for the selected protocol."""
import asyncio
import json
import os
import signal
import socket
import sys
import threading

from fastmcp import Client, FastMCP
from fastmcp.client.transports import StdioTransport


def server():
    mcp = FastMCP("python-interop")

    @mcp.tool
    def echo(value: int) -> dict:
        return {"value": value}

    @mcp.tool
    def empty() -> dict:
        return {}

    @mcp.resource("data://interop/value")
    def resource() -> str:
        return "hello"

    return mcp


async def check_client(mode, target):
    if target == "stdio":
        command, *args = json.loads(sys.argv[4])
        target = StdioTransport(command=command, args=args, keep_alive=False)
    async with Client(target, mode=mode) as client:
        tools = await client.list_tools()
        assert {tool.name for tool in tools} == {"echo", "empty"}
        result = await client.call_tool("echo", {"value": 42})
        assert result.structured_content == {"value": 42}
        result = await client.call_tool("empty", {})
        assert result.structured_content == {}
        resource = await client.read_resource("data://interop/value")
        assert resource[0].text == "hello"
    print("interop-ok", flush=True)


if sys.argv[1] == "server-stdio":
    server().run(transport="stdio", show_banner=False)
elif sys.argv[1] == "server-http":
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    print(f"PORT:{sock.getsockname()[1]}", flush=True)

    def stop_on_eof():
        sys.stdin.buffer.read()
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=stop_on_eof, daemon=True).start()
    asyncio.run(server().run_http_async(
        host="127.0.0.1", sockets=[sock], show_banner=False, log_level="error"
    ))
else:
    asyncio.run(check_client(sys.argv[2], sys.argv[3]))
