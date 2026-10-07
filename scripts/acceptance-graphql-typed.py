#!/usr/bin/env python3
"""Frozen engineering controls against official graphql-core and a real HTTP server.

Uses only the seven RIGHTCLICK operations for runtime actions. This deterministic
driver is not a fresh AI and cannot satisfy the eleven-world acceptance gate.
Install graphql-core==3.3.0 and cryptography==46.0.5 in an isolated environment.
"""
import argparse
import base64
import hashlib
import http.server
import importlib.util
import json
import pathlib
import tempfile
import threading
import time
import urllib.request
import uuid

import graphql
from graphql import build_schema, graphql_sync

client_spec = importlib.util.spec_from_file_location("canonical_client", pathlib.Path(__file__).with_name("canonical-mcp-proof-client.py"))
client_module = importlib.util.module_from_spec(client_spec); client_spec.loader.exec_module(client_module)
Client, signer, verify = client_module.Client, client_module.signer, client_module.verify


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    marker = "GQL_" + uuid.uuid4().hex
    mutate, scalar, custom, recursive = [prefix + uuid.uuid4().hex[:12] for prefix in ("record_", "number_", "opaque_", "recursive_")]
    nullable_echo, required_echo = ["echo_" + uuid.uuid4().hex[:12] for _ in range(2)]
    sdl = f"""
      enum Mode {{ FIRST SECOND }}
      input ChildInput {{ flag: Boolean!, count: Int!, note: String }}
      input Payload {{ children: [ChildInput!]!, mode: Mode!, ratio: Float!, absent: Boolean }}
      input Recursive {{ child: Recursive, text: String }}
      scalar Unspecified
      type Child {{ flag: Boolean!, count: Int!, note: String }}
      type Record {{ nonce: String!, children: [Child!]!, mode: Mode!, ratio: Float!, absent: Boolean }}
      type Query {{ {scalar}: Float!, {custom}: Unspecified, {recursive}(value: Recursive): String,
                    {nullable_echo}(value: String): String, {required_echo}(value: String!): String! }}
      type Mutation {{ {mutate}(nonce: String!, payload: Payload!): Record! }}
    """
    schema = build_schema(sdl)
    schema.get_type("Query").fields[scalar].resolve = lambda *_: 1.0
    schema.get_type("Query").fields[custom].resolve = lambda *_: "unspecified"
    schema.get_type("Query").fields[recursive].resolve = lambda *_, **__: "unused"
    state = {"online": True, "drift": False, "invalid_result": False}
    effects = []; requests = []
    lock = threading.Lock()
    def mutation(_root, _info, nonce, payload):
        result = {"nonce": nonce, **payload}
        with lock:
            effects.append(result)
            with (out / "effects.jsonl").open("a") as stream: stream.write(json.dumps(result) + "\n")
            (out / (hashlib.sha256(nonce.encode()).hexdigest() + ".state.json")).write_text(json.dumps(result))
        return result
    schema.get_type("Mutation").fields[mutate].resolve = mutation
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def reply(self, code, value):
            data = json.dumps(value).encode()
            self.send_response(code); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            if self.path.startswith("/observe/"):
                nonce = self.path.split("/observe/", 1)[1]
                # Separate state read, never an echo of the mutation response.
                found = next((value for value in reversed(effects) if value["nonce"] == nonce), None)
                with (out / "observations.jsonl").open("a") as stream:
                    stream.write(json.dumps({"nonce": nonce, "found": found is not None}) + "\n")
                data = nonce.encode() if found else b"missing"
                self.send_response(200 if found else 404); self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
                return
            self.reply(404, None)
        def do_POST(self):
            if not state["online"]: return self.reply(503, {"errors": [{"message": "withdrawn"}]})
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            introspection = "__schema" in data["query"]
            if not introspection:
                requests.append(data)
                with (out / "provider-requests.jsonl").open("a") as stream: stream.write(json.dumps(data) + "\n")
            current = build_schema(sdl.replace("mode: Mode!", "mode: String!") if state["drift"] else sdl)
            current.get_type("Query").fields[scalar].resolve = lambda *_: 1.0
            current.get_type("Query").fields[nullable_echo].resolve = lambda *_, value=None: value
            current.get_type("Query").fields[required_echo].resolve = lambda *_, value: value
            current.get_type("Mutation").fields[mutate].resolve = mutation
            result = graphql_sync(current, data["query"], variable_values=data.get("variables"), operation_name=data.get("operationName"))
            body = result.formatted
            if state["invalid_result"] and not introspection and body.get("data"):
                value = body["data"].get("rightclickResult")
                if isinstance(value, dict): value["children"][0]["flag"] = 1
            self.reply(200, body)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/graphql"
    (out / "schema.graphql").write_text(sdl)
    report = {"boundary": "Real GraphQL engineering pressure; not the fresh-AI eleven-world acceptance.",
              "graphqlCoreVersion": graphql.__version__, "binary": str(args.binary.resolve()),
              "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "controls": {}}
    controls = report["controls"]
    def check(name, assertion):
        try:
            assertion(); controls[name] = {"result": "PASS"}
        except Exception as error:
            controls[name] = {"result": "FAIL", "error": str(error)}
    def require(value, reason):
        if not value: raise AssertionError(reason)
    module_spec = importlib.util.spec_from_file_location("receipt_verifier", pathlib.Path(__file__).with_name("verify-rcir-receipt.py"))
    verifier = importlib.util.module_from_spec(module_spec); module_spec.loader.exec_module(verifier)
    with tempfile.TemporaryDirectory(prefix="rightclick-graphql-private-") as private:
        private = pathlib.Path(private)
        public = signer(private, out)
        host = {"version": 1, "revision": marker, "deniedCapabilities": [], "signingKeyFile": str(private / "key.raw")}
        config = private / "host.json"
        def configure(): config.write_text(json.dumps(host)); config.chmod(0o600)
        configure()
        client = None
        try:
            # Independently establish that official GraphQL accepts the exact typed input.
            payload = {"children": [{"flag": True, "count": 2147483647, "note": None}], "mode": "SECOND", "ratio": 1.0, "absent": None}
            native = {"query": f"mutation($nonce:String!,$payload:Payload!){{{mutate}(nonce:$nonce,payload:$payload){{nonce children{{flag count note}} mode ratio absent}}}}",
                      "variables": {"nonce": "native-control", "payload": payload}}
            response = json.load(urllib.request.urlopen(urllib.request.Request(endpoint, json.dumps(native).encode(), {"Content-Type": "application/json"}), timeout=5))
            require("errors" not in response and effects[-1]["children"][0]["count"] == 2147483647, "native GraphQL control failed")
            (out / "native-control.json").write_text(json.dumps(response, indent=2))
            effects.clear(); requests.clear()
            client = Client(args.binary, out, {"RIGHTCLICK_RCIR_CONFIG": str(config), "RIGHTCLICK_CAPABILITY_EXPERIENCE": "disabled",
                "RIGHTCLICK_CAPABILITY_ARTIFACTS": json.dumps([{"id": marker, "kind": "graphql", "endpointURL": endpoint}])})
            report["runtime"] = client.runtime; report["tools"] = client.tools
            client.call("context_providers", {}); client.call("context_inspect", {"item": marker})
            actions = client.call("context_actions", {"item": marker})["actions"]
            action = next(value for value in actions if value["title"] == "GraphQL mutation: " + mutate)
            number = next(value for value in actions if value["title"] == "GraphQL query: " + scalar)
            explained = client.call("context_explain", {"item": marker, "actionId": action["id"]})
            (out / "explanation.json").write_text(json.dumps(explained, indent=2))
            check("unsupported_scalar_abstains", lambda: require(not any(value["title"].endswith(custom) for value in actions), "unsupported scalar was advertised"))
            check("recursive_input_abstains", lambda: require(not any(value["title"].endswith(recursive) for value in actions), "recursive input was advertised"))
            def run(nonce, value=payload, confirmed=True):
                return client.call("context_run", {"item": marker, "actionId": action["id"], "confirmed": confirmed,
                    "arguments": {"nonce": nonce, "payload": json.dumps(value, separators=(",", ":"))}})
            denied = run("unconfirmed", confirmed=False)
            check("confirmation_zero_effect", lambda: require(denied["state"] == "awaiting_user" and not requests and not effects, str(denied)))
            nonce = "run_" + uuid.uuid4().hex
            good = run(nonce); report["invocation"] = good
            check("real_typed_effect", lambda: require(len(effects) == 1 and effects[0] == {"nonce": nonce, **payload}, str(effects)))
            check("independent_file_effect", lambda: require(json.loads((out / (hashlib.sha256(nonce.encode()).hexdigest() + ".state.json")).read_text()) == {"nonce": nonce, **payload}, "external state mismatch"))
            check("accepted_unverified", lambda: require(good["state"] == "accepted" and good["rcir"]["outcome"] == "unverified", str(good)))
            signed = verify(good, private, out, public)
            (out / "typed-mutation-receipt.json").write_text(json.dumps(good["rcir"]["signedReceipt"], indent=2))
            receipt = verifier._domain(signed, "RECEIPT"); request = verifier._domain(receipt["request"], "REQUEST")
            binding = verifier._domain(request["binding"], "BINDING"); contract = verifier._domain(binding["contract"], "CONTRACT")
            abi = verifier._value(contract["abi"][len(b"RIGHTCLICK-CONTRACT-1\0"):])
            typed_input = verifier._value(request["arguments"])
            typed_result = verifier._value(receipt["events"][-1])["value"]
            check("signed_input_object_types", lambda: require(typed_input == {"nonce": nonce, "payload": payload} and isinstance(typed_input["payload"], dict), str(typed_input)))
            check("signed_input_schema_closed", lambda: require(isinstance(verifier._value(abi["arguments"])["object"]["payload"], dict), "payload ABI schema is string"))
            check("signed_result_object_types", lambda: require(isinstance(typed_result, dict) and type(typed_result["rightclickResult"]["children"][0]["flag"]) is bool and type(typed_result["rightclickResult"]["ratio"]) is float, str(typed_result)))
            check("signed_result_schema_closed", lambda: require(isinstance(verifier._value(abi["result"]), dict), "result ABI schema is string"))
            status = client.call("context_run_status", {"executionId": good["executionId"]})
            check("status_same_signed_task", lambda: require(status["rcir"] == good["rcir"], str(status)))
            for label, change in [("numeric_boolean", {"children": [{"flag": 1, "count": 1}]}),
                                  ("int_overflow", {"children": [{"flag": True, "count": 2147483648}]}),
                                  ("enum_unknown", {"mode": "UNDECLARED"}),
                                  ("nested_extra", {"children": [{"flag": True, "count": 1, "extra": "x"}]}),
                                  ("non_null_null", {"children": [None]})]:
                previous_requests, previous_effects = len(requests), len(effects)
                invalid = run(label, {**payload, **change})
                check(label + "_pretransport", lambda invalid=invalid, previous_requests=previous_requests, previous_effects=previous_effects:
                    require(invalid["state"] == "failed" and len(requests) == previous_requests and len(effects) == previous_effects, str(invalid)))
            # Schema-valid provider completion is still separate from independent state readback.
            host["observers"] = {action["id"]: {"urlTemplate": endpoint.replace("/graphql", "/observe/{nonce}"), "expectedArgument": "nonce"}}
            configure(); observed_nonce = "observed_" + uuid.uuid4().hex; observed = run(observed_nonce)
            check("independent_http_readback", lambda: require(observed["state"] == "succeeded" and effects[-1]["nonce"] == observed_nonce, str(observed)))
            # A malformed provider result after a real effect must never become verified success.
            state["invalid_result"] = True
            malformed = run("invalid_result_" + uuid.uuid4().hex); state["invalid_result"] = False
            check("malformed_result_unknown", lambda: require(malformed["state"] == "unknown" and malformed["rcir"]["outcome"] == "unknown", str(malformed)))
            number_result = client.call("context_run", {"item": marker, "actionId": number["id"], "confirmed": True})
            number_payload = verify(number_result, private, out, public)
            number_value = verifier._value(verifier._domain(number_payload, "RECEIPT")["events"][-1])["value"]
            check("whole_float_keeps_number_type", lambda: require(isinstance(number_value, dict) and type(number_value["rightclickResult"]) is float, str(number_value)))
            # Version-two preregistration: preserve all nullable string values
            # through the declared legacy-text codec, including the null sentinel.
            for label, field, supplied, expected in [
                ("nullable_null", nullable_echo, "null", None),
                ("nullable_plain_string", nullable_echo, "ordinary", "ordinary"),
                ("required_literal_null", required_echo, "null", "null"),
                ("nullable_literal_null_escape", nullable_echo, "\\null", "null"),
                ("nullable_leading_backslash_escape", nullable_echo, "\\\\text", "\\text"),
                ("nullable_backslash_null_escape", nullable_echo, "\\\\null", "\\null")]:
                echo = next(value for value in actions if value["title"] == "GraphQL query: " + field)
                echoed = client.call("context_run", {"item": marker, "actionId": echo["id"], "confirmed": True, "arguments": {"value": supplied}})
                echo_payload = verify(echoed, private, out, public)
                echo_value = verifier._value(verifier._domain(echo_payload, "RECEIPT")["events"][-1])["value"]
                check(label, lambda echo_value=echo_value, expected=expected: require(echo_value == {"rightclickResult": expected}, str(echo_value)))
            state["drift"] = True; time.sleep(5.3)
            previous = len(effects)
            stale = run("stale-schema")
            check("schema_drift_stale_zero_effect", lambda: require(stale["state"] in ("unavailable", "failed", "rejected") and len(effects) == previous, str(stale)))
            state["online"] = False; time.sleep(5.3)
            disappeared = client.call("context_actions", {"item": marker})["actions"]
            check("withdrawal_removes_capability", lambda: require(not any(value["id"] == action["id"] for value in disappeared), "withdrawn action retained"))
            require(len(client.request("tools/list")["tools"]) == 7, "tool count changed")
        except Exception as error:
            report["setupOrUnexpectedFailure"] = str(error)
        finally:
            if client: client.close()
            server.shutdown(); server.server_close()
            report["result"] = "PASS" if controls and all(value["result"] == "PASS" for value in controls.values()) and "setupOrUnexpectedFailure" not in report else "FAIL"
            (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"result": report["result"], "controls": controls, "unexpected": report.get("setupOrUnexpectedFailure")}, indent=2))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
