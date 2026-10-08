#!/usr/bin/env python3
"""Disposable genuine protocols; independent observer is a separate process.

The HTTP role uses graphql-core parsing, validation and introspection. The gRPC
role uses the official grpcio HTTP/2 server, dynamic protobuf descriptors and
grpcio-reflection. Neither role is a RIGHTCLICK execution adapter.
"""
import argparse
import json
import pathlib
import re
import socket
from http.server import BaseHTTPRequestHandler
from fixture_http import LoopbackThreadingHTTPServer


def valid(value):
    return isinstance(value, str) and re.fullmatch(r"[a-zA-Z0-9-]{1,128}", value) is not None


def write_effect(root, family, challenge, value):
    if not valid(challenge) or not isinstance(value, str) or len(value.encode()) > 8192:
        raise ValueError("Invalid bounded fixture request")
    directory = root / "records" / family
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    (directory / challenge).write_text(value)


def ready(root, role, port):
    temporary = root / (role + "-port.pending")
    temporary.write_text(str(port))
    temporary.chmod(0o600)
    temporary.replace(root / (role + "-port"))


def http_server(root, role):
    graphql_schema = None
    if role == "http":
        from graphql import build_schema, graphql_sync
        graphql_schema = build_schema("type Proof { challenge: String!, value: String! }\n"
            "type Query { health: String! }\ntype Mutation { storeProof(challenge: String!, value: String!): Proof! }")
        graphql_schema.query_type.fields["health"].resolve = lambda *_: "ready"
        def store(_source, _info, challenge, value):
            write_effect(root, "graphql", challenge, value)
            return {"challenge": challenge, "value": value}
        graphql_schema.mutation_type.fields["storeProof"].resolve = store
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def reply(self, value, status=200, *, text=False):
            data = value.encode() if text else json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain" if text else "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def do_GET(self):
            if self.path == "/health":
                return self.reply({"ready": role})
            if role == "observer" and self.path.startswith("/observe/"):
                components = self.path.split("/")
                if len(components) != 4 or components[2] not in {"openapi", "graphql", "grpc", "ard", "mcp"} or not valid(components[3]):
                    return self.reply({"error": "invalid observation"}, 400)
                try:
                    data = (root / "records" / components[2] / components[3]).read_text()
                except FileNotFoundError:
                    return self.reply({"error": "absent"}, 404)
                if len(data.encode()) > 8192:
                    return self.reply({"error": "observation bound"}, 413)
                return self.reply(data, text=True)
            if role == "http" and self.path in {"/openapi.json", "/ard-openapi.json"}:
                family = "ard" if self.path.startswith("/ard-") else "openapi"
                schema = {"type": "object", "additionalProperties": False,
                          "required": ["challenge", "value"],
                          "properties": {"challenge": {"type": "string"}, "value": {"type": "string"}}}
                content = {"application/json": {"schema": schema}}
                spec = {"openapi": "3.0.3", "info": {"title": "Coexistence " + family, "version": "1"},
                        "servers": [{"url": "http://127.0.0.1:" + str(self.server.server_port)}],
                        "paths": {"/store/" + family: {"post": {
                            "operationId": "store" + family.title(), "summary": "Store disposable " + family + " proof",
                            "requestBody": {"required": True, "content": content},
                            "responses": {"200": {"description": "accepted", "content": content}}}}}}
                if (root / ("withdraw-" + family)).exists():
                    spec["paths"] = {}
                return self.reply(spec)
            return self.reply({"error": "absent"}, 404)
        def do_POST(self):
            try:
                if role != "http":
                    return self.reply({"error": "read-only observer"}, 403)
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 262144:
                    return self.reply({"error": "request bound"}, 413)
                body = json.loads(self.rfile.read(length))
                if self.path == "/graphql":
                    if (root / "withdraw-graphql").exists():
                        return self.reply({"error": "withdrawn"}, 404)
                    result = graphql_sync(graphql_schema, body.get("query", ""), variable_values=body.get("variables"),
                                          operation_name=body.get("operationName"))
                    response = {"data": result.data}
                    if result.errors:
                        response["errors"] = [{"message": error.message} for error in result.errors]
                    return self.reply(response)
                if self.path == "/ard/search":
                    if not isinstance(body.get("query", {}).get("text"), str):
                        return self.reply({"error": "invalid contextual query"}, 400)
                    rows = [] if (root / "withdraw-ard").exists() else [{
                        "identifier": "urn:air:coexistence:ard", "displayName": "Actual contextual ARD HTTP contract",
                        "type": "application/openapi+json", "url": "http://127.0.0.1:" + str(self.server.server_port) + "/ard-openapi.json",
                        "score": 100, "source": "controlled genuine ARD registry"}]
                    return self.reply({"results": rows})
                if self.path in {"/store/openapi", "/store/ard"}:
                    family = self.path.rsplit("/", 1)[-1]
                    write_effect(root, family, body["challenge"], body["value"])
                    return self.reply(body)
                return self.reply({"error": "absent"}, 404)
            except (KeyError, ValueError, TypeError):
                return self.reply({"error": "invalid bounded request"}, 400)
    server = LoopbackThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    ready(root, role, server.server_port)
    server.serve_forever()


def grpc_server(root):
    import grpc
    from concurrent.futures import ThreadPoolExecutor
    from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
    from grpc_reflection.v1alpha import reflection
    description = descriptor_pb2.FileDescriptorProto(name="rightclick-coexistence.proto", package="rightclick.coexistence", syntax="proto3")
    for name in ["StoreRequest", "StoreResponse"]:
        message = description.message_type.add(name=name)
        for number, field in enumerate(["challenge", "value"], 1):
            message.field.add(name=field, number=number, label=descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL,
                              type=descriptor_pb2.FieldDescriptorProto.TYPE_STRING)
    service = description.service.add(name="Proof")
    service.method.add(name="Store", input_type=".rightclick.coexistence.StoreRequest", output_type=".rightclick.coexistence.StoreResponse")
    pool = descriptor_pool.Default()
    pool.AddSerializedFile(description.SerializeToString())
    request_type = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.coexistence.StoreRequest"))
    response_type = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.coexistence.StoreResponse"))
    def store(request, context):
        try:
            write_effect(root, "grpc", request.challenge, request.value)
        except ValueError:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "invalid bounded fixture input")
        return response_type(challenge=request.challenge, value=request.value)
    server = grpc.server(ThreadPoolExecutor(max_workers=4), options=[("grpc.max_receive_message_length", 262144), ("grpc.max_send_message_length", 262144)])
    server.add_generic_rpc_handlers((grpc.method_handlers_generic_handler("rightclick.coexistence.Proof", {
        "Store": grpc.unary_unary_rpc_method_handler(store, request_deserializer=request_type.FromString,
                                                      response_serializer=lambda response: response.SerializeToString())}),))
    reflection.enable_server_reflection(("rightclick.coexistence.Proof", reflection.SERVICE_NAME), server)
    port = server.add_insecure_port("127.0.0.1:0")
    if not port:
        raise RuntimeError("No loopback gRPC fixture listener")
    server.start()
    ready(root, "grpc", port)
    server.wait_for_termination()


def mcp_server(root):
    import contextlib
    from mcp import types
    from mcp.server import Server
    from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
    from starlette.applications import Starlette
    from starlette.responses import JSONResponse
    from starlette.routing import Route
    import uvicorn
    server = Server("RIGHTCLICK-coexistence-MCP", version="1")
    schema = {"type": "object", "properties": {"challenge": {"type": "string"}},
              "required": ["challenge"], "additionalProperties": False}
    @server.list_tools()
    async def tools():
        acquired = dict(schema)
        if (root / "withdraw-mcp").exists():
            acquired["unsupportedFixtureConstraint"] = True
        return [types.Tool(name="record_challenge", title="Record disposable challenge", inputSchema=acquired, outputSchema=schema)]
    @server.call_tool()
    async def call(name, arguments):
        if name != "record_challenge" or (root / "withdraw-mcp").exists():
            raise ValueError("Unknown or withdrawn tool")
        challenge = arguments["challenge"]
        write_effect(root, "mcp", challenge, challenge)
        return {"challenge": challenge}
    manager = StreamableHTTPSessionManager(server, json_response=True, stateless=True)
    class MCPASGI:
        async def __call__(self, scope, receive, send):
            await manager.handle_request(scope, receive, send)
    async def health(_request):
        return JSONResponse({"ready": "mcp"})
    @contextlib.asynccontextmanager
    async def lifespan(_app):
        async with manager.run():
            yield
    application = Starlette(routes=[Route("/health", health), Route("/mcp", MCPASGI())], lifespan=lifespan)
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    ready(root, "mcp", listener.getsockname()[1])
    uvicorn.Server(uvicorn.Config(application, log_level="warning")).run(sockets=[listener])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("role", choices=["http", "observer", "grpc", "mcp"])
    args = parser.parse_args()
    args.root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.role in {"http", "observer"}:
        http_server(args.root, args.role)
    elif args.role == "grpc":
        grpc_server(args.root)
    else:
        mcp_server(args.root)


if __name__ == "__main__":
    main()
