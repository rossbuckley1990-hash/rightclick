#!/usr/bin/env python3
"""Official native gRPC/reflection fixture on private loopback only.

The client mode is an independent engineering control, never an agent tool.
Descriptors are assembled with the official protobuf runtime; RIGHTCLICK must
acquire them from the real reflection service rather than fixture-generated stubs.
"""
import argparse
import concurrent.futures
import hashlib
import http.server
import json
import os
import pathlib
import threading
import time

import grpc
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory
from grpc_reflection.v1alpha import reflection

file = descriptor_pb2.FileDescriptorProto(
    name="stream-pressure.proto", package="rightclick.pressure", syntax="proto3")
request = file.message_type.add(name="Request")
request.field.add(name="challenge", number=1, label=1, type=9)
request.field.add(name="count", number=2, label=1, type=5)
request.field.add(name="mode", number=3, label=1, type=9)
request.field.add(name="expected_digest", number=4, label=1, type=9)
response = file.message_type.add(name="Element")
response.field.add(name="sequence", number=1, label=1, type=5)
response.field.add(name="value", number=2, label=1, type=9)
response.field.add(name="wide", number=3, label=1, type=3)
response.field.add(name="enabled", number=4, label=1, type=8)
response.field.add(name="blob", number=5, label=1, type=12)
response.oneof_decl.add(name="_optional_note")
response.field.add(name="optional_note", number=6, label=1, type=9,
                   proto3_optional=True, oneof_index=0)
unary_response = file.message_type.add(name="UnaryElement")
unary_response.field.add(name="value", number=1, label=1, type=9)
service = file.service.add(name="Streams")
service.method.add(name="Read", input_type=".rightclick.pressure.Request",
                   output_type=".rightclick.pressure.Element", server_streaming=True)
service.method.add(name="Echo", input_type=".rightclick.pressure.Request",
                   output_type=".rightclick.pressure.UnaryElement")
pool = descriptor_pool.Default()
pool.Add(file)
Request = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.pressure.Request"))
Element = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.pressure.Element"))
UnaryElement = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.pressure.UnaryElement"))

parser = argparse.ArgumentParser()
parser.add_argument("--directory", type=pathlib.Path)
parser.add_argument("--control", type=int)
parser.add_argument("--challenge")
parser.add_argument("--mode", default="normal")
parser.add_argument("--count", type=int, default=3)
parser.add_argument("--observer", action="store_true")
args = parser.parse_args()

def publish_port(directory, role, port):
    temporary = directory / (role + "-port.tmp")
    temporary.write_text(str(port), encoding="ascii")
    os.chmod(temporary, 0o600)
    temporary.replace(directory / (role + "-port"))

def rows(path):
    if not path.exists():
        return []
    # A completed newline is the publication boundary, not file existence.
    return [json.loads(line) for line in path.read_bytes().splitlines(keepends=True)
            if line.endswith(b"\n")]

if args.observer:
    if args.directory is None:
        parser.error("observer mode requires --directory")
    class Observer(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            challenge = self.path.removeprefix("/observations/")
            matches = [row for row in rows(args.directory / "stream-events.jsonl")
                       if row.get("challenge") == challenge]
            starts = [row for row in matches if row["kind"] == "started"]
            elements = [row for row in matches if row["kind"] == "element"]
            done = [row for row in matches if row["kind"] == "completed"]
            marker = self.headers.get("X-RightClick-Invocation")
            valid = len(starts) == 1 and len(done) == 1 and starts[0]["invocation"] == marker
            observation = {"challenge": challenge, "markerMatched": valid,
                           "elementCount": len(elements)}
            with (args.directory / "observations.jsonl").open("a") as output:
                output.write(json.dumps(observation, sort_keys=True) + "\n")
            if not valid:
                self.send_response(404); self.end_headers(); return
            digest = hashlib.sha256("".join(str(row["sequence"]) + ":" + row["value"] + "\n"
                                             for row in elements).encode()).hexdigest()
            body = json.dumps({"challenge": challenge, "digest": digest,
                               "phase": "completed", "count": len(elements), "invocation": marker}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *unused):
            pass
    observer = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Observer)
    publish_port(args.directory, "observer", observer.server_port)
    observer.serve_forever()
    raise SystemExit
if args.control is not None:
    with grpc.insecure_channel("127.0.0.1:" + str(args.control)) as channel:
        stream = channel.unary_stream("/rightclick.pressure.Streams/Read",
                                      request_serializer=Request.SerializeToString,
                                      response_deserializer=Element.FromString)
        values = [{"sequence": item.sequence, "value": item.value, "wide": item.wide,
                   "enabled": item.enabled, "blob": item.blob.hex(),
                   "optional_present": item.HasField("optional_note")}
                  for item in stream(Request(challenge=args.challenge, count=args.count, mode=args.mode), timeout=5)]
        print(json.dumps(values), flush=True)
else:
    if args.directory is None:
        parser.error("server mode requires --directory")
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    journal = args.directory / "stream-events.jsonl"
    lock = threading.Lock()

    def record(value):
        with lock, journal.open("a") as output:
            output.write(json.dumps(value, sort_keys=True) + "\n")

    def read(request, context):
        metadata = dict(context.invocation_metadata())
        invocation = metadata.get("rightclick.invocation")
        record({"kind": "started", "challenge": request.challenge, "invocation": invocation})
        count = request.count or 3
        if not 1 <= count <= 512:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "bounded count required")
        for index in range(1, count + 1):
            if not context.is_active():
                record({"kind": "cancelled", "challenge": request.challenge, "invocation": invocation})
                return
            sequence = 7 if request.mode == "duplicate" else index
            value = "" if request.mode == "defaults" else request.challenge + ":" + str(sequence)
            wide = (9223372036854775807 if index % 2 else -9223372036854775808) if request.mode == "wide" else 0
            if request.mode == "malformed":
                record({"kind": "malformed", "challenge": request.challenge, "invocation": invocation})
                yield b"\x12\xff\xff\xff\xff\xff\xff\xff\xff\x7f"
                return
            record({"kind": "element", "sequence": sequence, "value": value, "wide": wide,
                    "enabled": False, "blob": "", "optional_present": False,
                    "challenge": request.challenge, "invocation": invocation})
            item = Element(sequence=sequence, value=value, wide=wide)
            # Valid repeated singular field: official protobuf last-value wins.
            yield b"\x08\x01" + item.SerializeToString() if request.mode == "duplicate" else item
            if request.mode == "held":
                while context.is_active():
                    time.sleep(0.01)
                record({"kind": "cancelled", "challenge": request.challenge, "invocation": invocation})
                return
            if request.mode == "normal":
                time.sleep(0.08)
        record({"kind": "completed", "challenge": request.challenge, "invocation": invocation})

    def echo(request, context):
        record({"kind": "unary", "challenge": request.challenge,
                "invocation": dict(context.invocation_metadata()).get("rightclick.invocation")})
        (args.directory / ("echo-" + request.challenge + ".txt")).write_text(request.challenge)
        return UnaryElement(value=request.challenge)

    server = grpc.server(concurrent.futures.ThreadPoolExecutor(max_workers=4),
                         options=(("grpc.max_send_message_length", 131072),))
    server.add_generic_rpc_handlers((grpc.method_handlers_generic_handler("rightclick.pressure.Streams", {
        "Read": grpc.unary_stream_rpc_method_handler(read,
            request_deserializer=Request.FromString,
            response_serializer=lambda value: value if isinstance(value, bytes) else value.SerializeToString()),
        "Echo": grpc.unary_unary_rpc_method_handler(echo,
            request_deserializer=Request.FromString, response_serializer=UnaryElement.SerializeToString)
    }),))
    reflection.enable_server_reflection(("rightclick.pressure.Streams", reflection.SERVICE_NAME), server)
    port = server.add_insecure_port("127.0.0.1:0")
    assert port > 0
    server.start()
    publish_port(args.directory, "provider", port)
    print(port, flush=True)
    server.wait_for_termination()
