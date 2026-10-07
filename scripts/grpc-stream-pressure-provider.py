#!/usr/bin/env python3
"""Official native gRPC/reflection fixture on private loopback only.

The client mode is an independent engineering control, never an agent tool.
Descriptors are assembled with the official protobuf runtime; RIGHTCLICK must
acquire them from the real reflection service rather than fixture-generated stubs.
"""
import argparse
import concurrent.futures
import json
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
response = file.message_type.add(name="Element")
response.field.add(name="sequence", number=1, label=1, type=5)
response.field.add(name="value", number=2, label=1, type=9)
service = file.service.add(name="Streams")
service.method.add(name="Read", input_type=".rightclick.pressure.Request",
                   output_type=".rightclick.pressure.Element", server_streaming=True)
pool = descriptor_pool.Default()
pool.Add(file)
Request = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.pressure.Request"))
Element = message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.pressure.Element"))

parser = argparse.ArgumentParser()
parser.add_argument("--directory", type=pathlib.Path)
parser.add_argument("--control", type=int)
parser.add_argument("--challenge")
args = parser.parse_args()
if args.control is not None:
    with grpc.insecure_channel("127.0.0.1:" + str(args.control)) as channel:
        stream = channel.unary_stream("/rightclick.pressure.Streams/Read",
                                      request_serializer=Request.SerializeToString,
                                      response_deserializer=Element.FromString)
        values = [{"sequence": item.sequence, "value": item.value}
                  for item in stream(Request(challenge=args.challenge), timeout=5)]
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
        for index in range(1, 4):
            if not context.is_active():
                record({"kind": "cancelled", "challenge": request.challenge, "invocation": invocation})
                return
            value = request.challenge + ":" + str(index)
            record({"kind": "element", "sequence": index, "value": value,
                    "challenge": request.challenge, "invocation": invocation})
            yield Element(sequence=index, value=value)
            time.sleep(0.08)
        record({"kind": "completed", "challenge": request.challenge, "invocation": invocation})

    server = grpc.server(concurrent.futures.ThreadPoolExecutor(max_workers=4),
                         options=(("grpc.max_send_message_length", 131072),))
    server.add_generic_rpc_handlers((grpc.method_handlers_generic_handler("rightclick.pressure.Streams", {
        "Read": grpc.unary_stream_rpc_method_handler(read,
            request_deserializer=Request.FromString, response_serializer=Element.SerializeToString)
    }),))
    reflection.enable_server_reflection(("rightclick.pressure.Streams", reflection.SERVICE_NAME), server)
    port = server.add_insecure_port("127.0.0.1:0")
    assert port > 0
    server.start()
    print(port, flush=True)
    server.wait_for_termination()
