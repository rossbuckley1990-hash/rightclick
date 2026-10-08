#!/usr/bin/env python3
"""Ephemeral REAL cloud first-contact probe. No target-specific MCP tools.

The machine-readable OpenAPI artifact below describes a deliberately narrow
publicly documented string-only subset of the third-party CRUD sandbox.
It is a contract, not a custom RIGHTCLICK provider or executable integration.
RIGHTCLICK owns reflection, argument checks, confirmation, and HTTP execution.
Independent stdlib HTTP calls are verification/cleanup, never the proof mutation.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import pathlib
import secrets
import selectors
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

TOOLS = {
    "context_runtime", "context_inspect", "context_actions",
    "context_explain", "context_run", "context_run_status", "context_providers",
}
CLOUD_URL = "https://restapi.fr"
COLLECTION = "rightclick_alien_" + secrets.token_hex(7)
COLLECTION_PATH = "/api/" + COLLECTION
PETSTORE_SPEC = "https://petstore3.swagger.io/api/v3/openapi.json"
PETSTORE_BASE = "https://petstore3.swagger.io/api/v3"
CLOUD_PROVIDER = "RIGHTCLICK First Contact - Public Cloud CRUD"
PETSTORE_PROVIDER = "Swagger Petstore - OpenAPI 3.0"

def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def cloud_contract():
    # One generic, supported, constrained OpenAPI projection of public endpoints.
    # Deliberately no undocumented query parameters, auth flows, or arbitrary paths.
    body = {
        "type": "object", "additionalProperties": False,
        "required": ["name", "data"],
        "properties": {"name": {"type": "string"}, "data": {"type": "string"}},
    }
    result = {"content": {"application/json": {"schema": {"type": "object"}}},
              "description": "JSON response"}
    path_id = [{"name": "id", "in": "path", "required": True,
                "schema": {"type": "string"}}]
    return {
        "openapi": "3.0.3",
        "info": {"title": CLOUD_PROVIDER, "version": "1.0.0",
                 "description": "Supported string-only contract subset of restapi.fr public temporary test storage"},
        "servers": [{"url": CLOUD_URL}],
        "paths": {
            COLLECTION_PATH: {
                "post": {
                    "operationId": "createObject",
                    "summary": "Create synthetic public cloud record",
                    "requestBody": {"required": True, "content": {
                        "application/json": {"schema": body}}},
                    "responses": {"200": result, "201": result},
                },
            },
            COLLECTION_PATH + "/{id}": {
                "get": {
                    "operationId": "readObject",
                    "summary": "Read cloud record by ID",
                    "parameters": path_id,
                    "responses": {"200": result},
                },
                "put": {
                    "operationId": "updateObject",
                    "summary": "Update synthetic cloud record",
                    "parameters": path_id,
                    "requestBody": {"required": True, "content": {
                        "application/json": {"schema": body}}},
                    "responses": {"200": result},
                },
            },
        },
    }

class MCP:
    def __init__(self, binary, out, name, env):
        self.name = name
        self.transcript = []
        self.id = 0
        self.stderr = (out / (name + "-stderr.log")).open("w")
        self.process = subprocess.Popen(
            [str(binary), "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, bufsize=1, env=env)
        self.raw("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "rightclick-unseen-cloud", "version": "1"}})
        self.process.stdin.write(json.dumps(
            {"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.process.stdin.flush()

    def raw(self, method, params=None, timeout=110):
        self.id += 1
        data = {"jsonrpc": "2.0", "id": self.id, "method": method}
        if params is not None:
            data["params"] = params
        assert self.process.poll() is None, "RIGHTCLICK subprocess exited"
        self.process.stdin.write(json.dumps(data, ensure_ascii=True) + "\n")
        self.process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                line = self.process.stdout.readline()
                if not line:
                    raise RuntimeError("RIGHTCLICK MCP closed stdout")
                answer = json.loads(line)
                if answer.get("id") != self.id:
                    continue
                self.transcript.append({"at": utc(), "request": data, "response": answer})
                if "error" in answer:
                    raise RuntimeError("MCP error: " + json.dumps(answer["error"]))
                return answer["result"]
        raise TimeoutError("RIGHTCLICK MCP timed out: " + method)

    def call(self, name, **kwargs):
        value = self.raw("tools/call", {"name": name, "arguments": kwargs})
        if value.get("isError"):
            raise RuntimeError("MCP tool error: " + json.dumps(value))
        return json.loads(value["content"][0]["text"])

    def tool_digest(self):
        listing = self.raw("tools/list")["tools"]
        assert {x["name"] for x in listing} == TOOLS, "AI-facing tool set changed"
        return hashlib.sha256(json.dumps(
            listing, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=8)
        self.stderr.close()

def remote_get(url):
    req = urllib.request.Request(url, headers={"Accept": "application/json",
                              "User-Agent": "RIGHTCLICK-first-contact-test/1"})
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            body = response.read(1024 * 128)
            return {"http_status": response.status, "body": body.decode("utf-8")}
    except urllib.error.HTTPError as e:
        return {"http_status": e.code,
                "body": e.read(1024 * 128).decode("utf-8", errors="replace")}

def remote_delete(url):
    req = urllib.request.Request(url, method="DELETE",
                headers={"User-Agent": "RIGHTCLICK-first-contact-teardown/1"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return {"http_status": r.status, "body": r.read(4096).decode("utf-8", errors="replace")}
    except urllib.error.HTTPError as e:
        return {"http_status": e.code, "body": e.read(4096).decode("utf-8", errors="replace")}

def parsed_output(record):
    if record.get("state") not in ("accepted", "succeeded"):
        raise RuntimeError("Provider did not accept: " + json.dumps(record)[:1300])
    return json.loads(record.get("output") or "null")

def cloud_actions(mcp, provider):
    actions = mcp.call("context_actions", item="RIGHTCLICK synthetic cloud first contact")["actions"]
    return [a for a in actions if a.get("provider", {}).get("name") == provider]

def main():
    p = argparse.ArgumentParser()
    p.add_argument("binary", type=pathlib.Path)
    p.add_argument("out", type=pathlib.Path)
    args = p.parse_args()
    binary = args.binary.resolve(strict=True)
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    artifact = cloud_contract()
    contract_bytes = json.dumps(artifact, sort_keys=True).encode()
    artifact_b64 = base64.b64encode(contract_bytes).decode()
    env = dict(os.environ)
    env.pop("RIGHTCLICK_CAPABILITY_ARTIFACTS", None)
    env.pop("RIGHTCLICK_OPENAPI_PROVIDERS", None)
    env["RIGHTCLICK_EXPERIENCE"] = "off"
    report = {
        "started_at_utc": utc(), "run_kind": "fresh_remote_cloud_runner",
        "target": CLOUD_URL, "remote_collection": COLLECTION, "petstore_native_schema": PETSTORE_SPEC,
        "contract_provenance": "Public documented REST endpoints, operator-supplied restricted OpenAPI; NOT provider native schema",
        "contract_sha256": hashlib.sha256(contract_bytes).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "tools_expected": sorted(TOOLS), "controls": {},
    }
    sessions = []
    record_id = None
    mutated = False
    try:
        baseline = MCP(binary, out, "before", env)
        sessions.append(baseline)
        report["before"] = {
            "tools_sha256": baseline.tool_digest(),
            "runtime": baseline.call("context_runtime"),
            "providers": baseline.call("context_providers"),
        }
        initial_actions = cloud_actions(baseline, CLOUD_PROVIDER)
        assert not initial_actions
        assert not cloud_actions(baseline, PETSTORE_PROVIDER)
        report["controls"]["no_preinstalled_cloud_provider"] = "PASS"
        baseline.close()

        configured = [
            {"id": "unseen-native-petstore", "kind": "openapi",
             "specificationURL": PETSTORE_SPEC, "baseURL": PETSTORE_BASE},
            {"id": "unseen-stateful-crud", "kind": "openapi",
             "inlineData": artifact_b64, "baseURL": CLOUD_URL},
        ]
        admitted_env = dict(env)
        admitted_env["RIGHTCLICK_CAPABILITY_ARTIFACTS"] = json.dumps(configured)
        cloud = MCP(binary, out, "after", admitted_env)
        sessions.append(cloud)
        report["after"] = {"tools_sha256": cloud.tool_digest(),
            "runtime": cloud.call("context_runtime"),
            "providers": cloud.call("context_providers")}
        assert report["after"]["tools_sha256"] == report["before"]["tools_sha256"]
        report["controls"]["same_exact_seven_mcp_tools"] = "PASS"

        petstore = cloud_actions(cloud, PETSTORE_PROVIDER)
        report["petstore"] = {"reflected_capabilities": len(petstore),
             "operation_ids": [x["title"] for x in petstore]}
        # Petstore has complex OAuth and structured payloads unsupported by the
        # stable executor; never run a protected operation or invent credentials.
        foreign = cloud_actions(cloud, CLOUD_PROVIDER)
        assert foreign, "The brand-new cloud capability artifact was not acquired"
        explained = {}
        for a in foreign:
            meta = cloud.call("context_explain", item="RIGHTCLICK synthetic cloud first contact", actionId=a["id"])
            explained[meta["metadata"]["operationId"]] = meta
        assert all(x in explained for x in ("createObject", "readObject", "updateObject")), (
            "Required generic CRUD subset could not be reflected: " + repr(sorted(explained)))
        report["discovered"] = [
            {"operation_id": key, "capability_id": a["id"], "method": a["metadata"]["method"],
             "path": a["metadata"]["path"], "argumentsSchema": a["metadata"].get("argumentsSchema")}
            for key, a in sorted(explained.items())]
        report["controls"]["novel_contract_reflected_without_new_mcp_tool"] = "PASS"
        def run(op, vals=None, confirmed=True):
            kwargs = {
                "item": "RIGHTCLICK synthetic cloud first contact",
                "actionId": explained[op]["id"],
                "confirmed": confirmed,
            }
            if vals is not None:
                kwargs["arguments"] = vals
            result = cloud.call("context_run", **kwargs)
            if result.get("executionId"):
                result["retained_status"] = cloud.call(
                    "context_run_status", executionId=result["executionId"])
            return result

        marker = "RIGHTCLICK-ALIEN-" + secrets.token_hex(10)
        sample = {"name": marker, "data": "created-" + secrets.token_hex(8)}
        withheld = run("createObject", sample, confirmed=False)
        report["confirmation_denial"] = withheld
        assert withheld["state"] == "awaiting_user"
        report["controls"]["unconfirmed_mutation_denied"] = "PASS"
        invalid = run("createObject", dict(sample, unexpected="not-in-contract"), confirmed=True)
        report["invalid_argument_control"] = invalid
        assert invalid["state"] in ("failed", "rejected")
        report["controls"]["undeclared_argument_denied"] = "PASS"

        created = run("createObject", sample)
        report["create"] = created
        observed = parsed_output(created)
        assert isinstance(observed, dict) and observed.get("_id") is not None, (
            "No actual remote ID after POST: " + repr(observed))
        record_id = str(observed["_id"])
        mutated = True
        if observed.get("name") != marker:
            raise RuntimeError("POST returned an incorrect marker")
        report["created_remote_id"] = record_id

        # Native reflected GET; independent read-back, not relying on POST 2xx.
        read = run("readObject", {"id": record_id})
        report["rightclick_readback"] = read
        obj = parsed_output(read)
        if not (obj.get("_id") == record_id and obj.get("name") == sample["name"]
                and obj.get("data") == sample["data"]):
            raise RuntimeError("RIGHTCLICK readback mismatch: " + repr(obj))
        remote = remote_get(CLOUD_URL + COLLECTION_PATH + "/" + record_id)
        report["independent_http_readback"] = remote
        assert remote["http_status"] == 200
        remote_obj = json.loads(remote["body"])
        assert remote_obj["_id"] == record_id
        assert remote_obj["name"] == sample["name"]
        assert remote_obj["data"] == sample["data"]
        report["controls"]["persistent_external_state_independently_verified"] = "PASS"

        changed = {"id": record_id, "name": marker + "-UPDATE",
                   "data": "updated-" + secrets.token_hex(8)}
        updated = run("updateObject", changed)
        report["update"] = updated
        # POST/PUT provider replies are not semantic success; verify by another GET.
        updated_read = run("readObject", {"id": record_id})
        report["updated_readback"] = updated_read
        obj2 = parsed_output(updated_read)
        if obj2["name"] != changed["name"] or obj2["data"] != changed["data"]:
            raise RuntimeError("PUT readback mismatch: " + repr(obj2))
        independent2 = remote_get(CLOUD_URL + COLLECTION_PATH + "/" + record_id)
        report["independent_updated_readback"] = independent2
        assert independent2["http_status"] == 200
        assert json.loads(independent2["body"])["name"] == changed["name"]
        report["controls"]["remote_update_independently_verified"] = "PASS"
        report["result"] = "PASS"
    except BaseException as exc:
        report["result"] = "FAIL"
        report["failure"] = type(exc).__name__ + ": " + str(exc)
        raise
    finally:
        # Published v0.2.2 does not reflect DELETE: independent operator cleanup
        # is explicit and is not misrepresented as a RIGHTCLICK execution.
        if record_id is not None and mutated:
            try:
                deleted = remote_delete(CLOUD_URL + COLLECTION_PATH + "/" + record_id)
                absence = remote_get(CLOUD_URL + COLLECTION_PATH + "/" + record_id)
                report["teardown"] = {"delete": deleted, "after_get": absence,
                     "operator_http_cleanup_not_rightclick": True,
                     "confirmed_absent": absence["http_status"] in (404, 410)}
                if not report["teardown"]["confirmed_absent"]:
                    report["result"] = "FAIL"
                    report["failure"] = "Public sandbox object not verified removed"
            except Exception as exc:
                report["result"] = "FAIL"
                report["teardown_error"] = str(exc)
        if sessions:
            for m in sessions:
                try:
                    (out / (m.name + "-transcript.json")).write_text(
                        json.dumps(m.transcript, indent=2, ensure_ascii=False) + "\n")
                finally:
                    m.close()
        # Re-acquisition removal: a brand-new process without artifact should
        # find no cloud provider while exposing the same seven MCP schemas.
        try:
            last = MCP(binary, out, "withdrawn", env)
            try:
                report["after_withdrawal"] = {"tools_sha256": last.tool_digest(),
                   "cloud_actions": len(cloud_actions(last, CLOUD_PROVIDER)),
                   "petstore_actions": len(cloud_actions(last, PETSTORE_PROVIDER))}
                assert report["after_withdrawal"]["tools_sha256"] == report["before"]["tools_sha256"]
                assert report["after_withdrawal"]["cloud_actions"] == 0
                assert report["after_withdrawal"]["petstore_actions"] == 0
                report["controls"]["no_capability_after_artifact_withdrawal"] = "PASS"
            finally:
                (out / "withdrawn-transcript.json").write_text(
                    json.dumps(last.transcript, indent=2) + "\n")
                last.close()
        except Exception as exc:
            report["withdrawal_error"] = str(exc)
            report["result"] = "FAIL"
        report["finished_at_utc"] = utc()
        (out / "report.json").write_text(json.dumps(
            report, indent=2, ensure_ascii=False) + "\n")
        print("RIGHTCLICK_FIRST_CONTACT_REPORT=" + json.dumps({
            "result": report["result"], "controls": report["controls"],
            "remote_id": report.get("created_remote_id"),
            "teardown": report.get("teardown", {}).get("confirmed_absent"),
            "failure": report.get("failure"),
        }), flush=True)
        if report["result"] != "PASS":
            sys.exit(1)

if __name__ == "__main__":
    main()
