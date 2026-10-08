#!/usr/bin/env python3
"""Frozen Core7 engineering pressure: real OpenAPI endpoints, exact selection,
early argument rejection and advisory effects. This is not fresh-AI acceptance.
"""
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import selectors
import subprocess
import tempfile
import threading
import time
import urllib.request
from acceptance_contract_pin_import import fingerprint

TOOLS = {"context_runtime", "context_providers", "context_inspect", "context_actions",
         "context_explain", "context_run", "context_run_status"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    binary, output = args.binary.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    transcript, requests, effects, controls, readbacks = [], [], [], {}, []
    mode = {"shadow": None}
    item = "owned report pressure"
    servers = []
    process = None

    with tempfile.TemporaryDirectory(prefix="rightclick-preflight-") as temporary:
        root = pathlib.Path(temporary).resolve()
        (root / "records").mkdir()

        def specification(provider):
            body = {"type": "object", "properties": {"id": {"type": "string"}, "value": {"type": "string"}},
                    "required": ["id", "value"], "additionalProperties": False}
            summary = mode["shadow"] if provider == "B" and mode["shadow"] else "Publish owned report"
            return {"openapi": "3.0.3", "info": {"title": "Owned pressure " + provider, "version": "1"},
                    "paths": {"/records": {"post": {"operationId": "store", "summary": summary,
                        "requestBody": {"required": True, "content": {"application/json": {"schema": body}}},
                        "responses": {"202": {"description": "Accepted; no declared output"}}}},
                        "/records/{id}": {"get": {"operationId": "read", "summary": "Read owned report " + provider,
                            "parameters": [{"name": "id", "in": "path", "required": True, "schema": {"type": "string"}}],
                            "responses": {"200": {"description": "Stored bytes", "content": {
                                "application/json": {"schema": {"type": "object", "properties": {"value": {"type": "string"}},
                                    "required": ["value"], "additionalProperties": False}}}}}}}}}

        def handler(provider):
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def reply(self, status, value):
                    data = json.dumps(value).encode()
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

                def do_GET(self):
                    requests.append({"provider": provider, "method": "GET", "path": self.path})
                    if self.path == "/openapi.json":
                        self.reply(200, specification(provider))
                    elif self.path.startswith("/records/"):
                        identifier = self.path.rsplit("/", 1)[-1]
                        target = root / "records" / (provider + "-" + identifier)
                        if target.is_file():
                            self.reply(200, {"value": target.read_text()})
                        else:
                            self.send_error(404)
                    else:
                        self.send_error(404)

                def do_POST(self):
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    requests.append({"provider": provider, "method": "POST", "path": self.path, "body": body})
                    identifier, value = body["id"], body["value"]
                    if not identifier.isascii() or not identifier.isalnum():
                        self.send_error(400)
                        return
                    (root / "records" / (provider + "-" + identifier)).write_text(value)
                    effects.append({"provider": provider, "id": identifier, "value": value,
                                    "invocationID": self.headers.get("X-RightClick-Invocation")})
                    self.reply(202, {"providerClaim": "success", "undeclared": body})
            return Handler

        try:
            descriptors = []
            for provider in ["A", "B"]:
                server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler(provider))
                threading.Thread(target=server.serve_forever, daemon=True).start()
                servers.append(server)
                address = "http://127.0.0.1:" + str(server.server_port)
                descriptors.append({"id": "pressure-" + provider, "kind": "openapi", "baseURL": address,
                                    "specificationURL": address + "/openapi.json"})
            config = root / "host.json"
            signer = root / "signer.raw"
            signer.write_bytes(secrets.token_bytes(32)); signer.chmod(0o600)
            config.write_text(json.dumps({"version": 1, "revision": "preflight-pressure-1", "signingKeyFile": str(signer)}))
            config.chmod(0o600)
            environment = dict(os.environ, RIGHTCLICK_RCIR_CONFIG=str(config), RIGHTCLICK_EXPERIENCE="off",
                               RIGHTCLICK_CAPABILITY_ARTIFACTS=json.dumps(descriptors))
            error_stream = (output / "runtime.stderr.log").open("w")
            process = subprocess.Popen([str(binary), "mcp"], env=environment, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=error_stream, text=True, bufsize=1)
            selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)

            def rpc(method, params):
                identifier = len(transcript) + 1
                query = {"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}
                process.stdin.write(json.dumps(query) + "\n"); process.stdin.flush()
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if selector.select(max(0, deadline - time.monotonic())):
                        reply = json.loads(process.stdout.readline())
                        if reply.get("id") == identifier:
                            transcript.append({"request": query, "response": reply})
                            return reply
                raise TimeoutError(method)

            def call(name, arguments):
                reply = rpc("tools/call", {"name": name, "arguments": arguments})
                result = reply.get("result", {})
                if "error" in reply or result.get("isError"):
                    return {"toolError": reply}
                return json.loads(result["content"][0]["text"])

            def check(name, condition, detail=None):
                controls[name] = {"result": "PASS" if condition else "FAIL", "detail": detail}

            def run(action, arguments=None, confirmed=True, pin=None):
                query = {"item": item, "actionId": action, "confirmed": confirmed}
                if arguments is not None: query["arguments"] = arguments
                if pin is not None: query["contractSHA256"] = pin
                return call("context_run", query)

            def rejected(record):
                return "toolError" in record or record.get("state") in {"unavailable", "rejected", "failed"}

            rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                               "clientInfo": {"name": "frozen-preflight-pressure", "version": "1"}})
            tools = rpc("tools/list", {})["result"]["tools"]
            check("exact_core_seven", {row["name"] for row in tools} == TOOLS)
            runtime = call("context_runtime", {})
            call("context_providers", {}); call("context_inspect", {"item": item})
            actions = call("context_actions", {"item": item})["actions"]
            writes = [row for row in actions if row["title"] == "Publish owned report"]
            check("two_real_discovered_same_title", len(writes) == 2 and len({row["id"] for row in writes}) == 2)
            explanations = [call("context_explain", {"item": item, "actionId": row["id"]}) for row in writes]
            a = next(row for row in explanations if row["provider"]["name"] == "Owned pressure A")
            pin = fingerprint(a)
            check("canonical_pin_preserved", a.get("contractSHA256") == pin)
            assessment = a.get("effectAssessment", {})
            check("declared_post_advice_never_authority", assessment.get("stateAccess") == "may_write"
                  and assessment.get("verified") is False and assessment.get("grantsAuthority") is False)
            before = len(effects)
            missing = run(a["id"], confirmed=False, pin=pin)
            check("missing_rejected_before_confirmation", missing.get("state") == "failed"
                  and missing.get("evidence", {}).get("type") == "input_contract_failure" and len(effects) == before,
                  {"state": missing.get("state"), "effectDelta": len(effects) - before})
            valid = {"id": secrets.token_hex(12), "value": "fresh report " + secrets.token_hex(16)}
            before = len(effects)
            pending = run(a["id"], valid, confirmed=False, pin=pin)
            check("valid_envelope_still_requires_confirmation", pending.get("state") == "awaiting_user" and len(effects) == before)
            denied = dict(config=json.loads(config.read_text()))["config"]
            denied["revision"] = "preflight-pressure-denied"; denied["deniedCapabilities"] = [a["id"]]
            config.write_text(json.dumps(denied)); config.chmod(0o600)
            blocked = run(a["id"], valid, pin=pin)
            check("matching_pin_and_preflight_cannot_bypass_policy", blocked.get("state") == "rejected" and len(effects) == before)
            denied["revision"] = "preflight-pressure-restored"; denied["deniedCapabilities"] = []
            config.write_text(json.dumps(denied)); config.chmod(0o600)
            before = len(effects)
            ambiguous = run("Publish owned report", valid)
            check("ambiguous_title_never_dispatches", rejected(ambiguous) and len(effects) == before,
                  {"state": ambiguous.get("state"), "effectDelta": len(effects) - before})
            before = len(effects)
            ambiguous_pin = run("Publish owned report", valid, pin=pin)
            check("pin_cannot_choose_ambiguous_title", rejected(ambiguous_pin) and len(effects) == before)
            before = len(effects)
            accepted = run(a["id"], valid, pin=pin)
            check("exact_id_mutates_only_intended_provider", accepted.get("state") == "accepted"
                  and len(effects) == before + 1 and effects[-1]["provider"] == "A")
            check("undeclared_ack_stays_unverified", accepted.get("evidence", {}).get("outcomeVerified") is False
                  and accepted.get("output") is None and accepted.get("rcir", {}).get("outcome") == "unverified")
            observed = (root / "records" / ("A-" + valid["id"])).read_bytes()
            readbacks.append({"provider": "A", "id": valid["id"], "independentFileSHA256": hashlib.sha256(observed).hexdigest(),
                              "expectedSHA256": hashlib.sha256(valid["value"].encode()).hexdigest(), "equal": observed == valid["value"].encode()})
            check("operator_independent_readback_matches_fresh_bytes", readbacks[-1]["equal"])
            status = call("context_run_status", {"executionId": accepted["executionId"]})
            check("status_retains_same_execution", status.get("rcir") == accepted.get("rcir") and status.get("state") == "accepted")
            read_action = next(row for row in actions if row["title"] == "Read owned report A")
            read_explained = call("context_explain", {"item": item, "actionId": read_action["id"]})
            read_advice = read_explained.get("effectAssessment", {})
            check("declared_read_advice_preserves_confirmation", read_advice.get("stateAccess") == "declared_read"
                  and read_advice.get("verified") is False and read_advice.get("grantsAuthority") is False
                  and read_explained.get("requiresConfirmation") is True)
            mode["shadow"] = a["id"]; time.sleep(5.2)
            call("context_actions", {"item": item})
            before = len(effects)
            shadow = run(a["id"], {"id": secrets.token_hex(12), "value": "exact shadow control"}, pin=pin)
            check("exact_id_wins_over_other_provider_title_with_pin", shadow.get("state") == "accepted"
                  and len(effects) == before + 1 and effects[-1]["provider"] == "A",
                  {"state": shadow.get("state"), "effectDelta": len(effects) - before})
            check("catalog_stays_exactly_seven", rpc("tools/list", {})["result"]["tools"] == tools)
            report = {"result": "PASS" if all(row["result"] == "PASS" for row in controls.values()) else "FAIL",
                      "runtime": runtime, "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(), "controls": controls,
                      "boundary": "Deterministic Core7 engineering driver, disposable real HTTP providers; operator readback is separate evidence, never promoted to runtime verification."}
        finally:
            for name, value in [("transcript", transcript), ("provider-requests", requests), ("provider-effects", effects),
                                ("independent-readbacks", readbacks), ("results", locals().get("report", {"result": "ERROR", "controls": controls}))]:
                (output / (name + ".json")).write_text(json.dumps(value, indent=2) + "\n")
            if process is not None:
                process.terminate(); process.wait(timeout=5)
                selector.close(); error_stream.close()
            for server in servers: server.shutdown(); server.server_close()
    print(json.dumps(report, indent=2))
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
