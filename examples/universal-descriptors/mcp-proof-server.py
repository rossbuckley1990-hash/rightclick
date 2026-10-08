#!/usr/bin/env python3
"""Genuine official-SDK MCP server, isolated loopback durable challenge proof."""
import argparse
import contextlib
import hashlib
import json
import pathlib
import re
import time

from mcp import types
from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from starlette.applications import Starlette
from starlette.responses import PlainTextResponse
from starlette.routing import Route
import uvicorn

parser = argparse.ArgumentParser()
parser.add_argument("--directory", required=True)
parser.add_argument("--port", type=int, default=19143)
args = parser.parse_args()
directory = pathlib.Path(args.directory).resolve()
directory.mkdir(parents=True, exist_ok=True)
server = Server("RIGHTCLICK-controlled-MCP-proof", version="1")
schema = {"type": "object", "properties": {"challenge": {"type": "string"}},
          "required": ["challenge"], "additionalProperties": False}


@server.list_tools()
async def list_tools():
    # The malformed switch is an isolated infrastructure control. It is never
    # offered as an agent tool and must cause acquisition to fail closed.
    acquired = dict(schema)
    if (directory / "malformed-descriptor").exists():
        acquired["unrecognizedSemanticConstraint"] = True
    return [types.Tool(name="record_challenge", title="Record disposable challenge",
                       description="Write the unique challenge inside this isolated proof directory.",
                       inputSchema=acquired, outputSchema=schema)]


@server.call_tool()
async def call_tool(name, arguments):
    if name != "record_challenge":
        raise ValueError("Unknown tool")
    challenge = arguments["challenge"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", challenge):
        raise ValueError("Bounded challenge token required")
    destination = directory / (hashlib.sha256(challenge.encode()).hexdigest() + ".txt")
    destination.write_text(challenge)
    with (directory / "effects.jsonl").open("a") as handle:
        handle.write(json.dumps({"challenge": challenge, "file": str(destination), "time": time.time()}) + "\n")
    return {"challenge": challenge}


manager = StreamableHTTPSessionManager(server, json_response=True, stateless=True)


async def mcp(request):
    await manager.handle_request(request.scope, request.receive, request._send)


async def observe(request):
    challenge = request.path_params["challenge"]
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", challenge):
        return PlainTextResponse("invalid", status_code=400)
    destination = directory / (hashlib.sha256(challenge.encode()).hexdigest() + ".txt")
    if not destination.exists():
        return PlainTextResponse("missing", status_code=404)
    value = destination.read_text()
    with (directory / "observations.jsonl").open("a") as handle:
        handle.write(json.dumps({"challenge": challenge, "value": value, "time": time.time()}) + "\n")
    return PlainTextResponse(value)


class MCPASGI:
    async def __call__(self, scope, receive, send):
        await manager.handle_request(scope, receive, send)


@contextlib.asynccontextmanager
async def lifespan(app):
    async with manager.run():
        yield


application = Starlette(routes=[Route("/mcp", MCPASGI(), methods=["POST", "GET", "DELETE"]),
                                Route("/observe/{challenge}", observe)], lifespan=lifespan)
uvicorn.run(application, host="127.0.0.1", port=args.port, log_level="warning")
