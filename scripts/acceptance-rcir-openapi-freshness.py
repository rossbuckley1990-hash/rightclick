#!/usr/bin/env python3
"""Additional live schema/cache proof; original seven production controls retained unchanged.
This is engineering workbench acceptance, not the restricted eleven-substrate agent.
No provider credentials, Docker, paid services or global client configuration.
"""
import argparse, base64, hashlib, http.server, json, os, pathlib, selectors
import subprocess, tempfile, threading, time, uuid

TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain",
         "context_run", "context_run_status", "context_providers"}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    binary = args.binary.resolve(); out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    transcript = []; effects = []; values = {}; mode = {"value": "correct"}
    marker = "RCIR-" + uuid.uuid4().hex
    schema = {"type":"object", "additionalProperties":False,
              "required":["id","value"], "properties":{"id":{"type":"string"}, "value":{"type":"string"}}}
    spec = {"openapi":"3.0.3", "info":{"title":marker,"version":"1"}, "paths":{
        "/records":{"post":{"operationId":"writeRecord", "summary":"Write disposable record",
        "requestBody":{"required":True,"content":{"application/json":{"schema":schema}}},
        "responses":{"200":{"description":"Accepted", "content":{"application/json":{"schema":schema}}}}}}}}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def reply(self, code, body, content):
            self.send_response(code); self.send_header("Content-Type",content); self.end_headers(); self.wfile.write(body)
        def do_GET(self):
            if self.path == "/openapi.json": return self.reply(200,json.dumps(spec).encode(),"application/json")
            if self.path.startswith("/records/"):
                ident = self.path[len("/records/"):]
                observation = {"method":"GET","path":self.path,"value":values.get(ident)}
                with (out/"observations.jsonl").open("a") as f: f.write(json.dumps(observation)+"\n")
                if ident in values: return self.reply(200, values[ident].encode(), "text/plain")
            self.reply(404,b"missing","text/plain")
        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            effect = {"method":"POST","path":self.path,"arguments":data,
                      "correlationID":self.headers.get("X-RightClick-Invocation")}
            effects.append(effect)
            with (out/"effects.jsonl").open("a") as f: f.write(json.dumps(effect)+"\n")
            if mode["value"] != "missing": values[data["id"]] = data["value"] if mode["value"] == "correct" else "WRONG"
            self.reply(200,json.dumps(data).encode(),"application/json")
    server = http.server.ThreadingHTTPServer(("0.0.0.0",0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    port = server.server_address[1]
    with tempfile.TemporaryDirectory(prefix="rightclick-rcir-acceptance-") as tmp:
        tmp = pathlib.Path(tmp)
        # Operator provisions a disposable signer; the runtime never generates an implicit identity.
        subprocess.run(["openssl","genpkey","-algorithm","ed25519","-out",str(tmp/"key.pem")],check=True,stdout=subprocess.DEVNULL)
        der = subprocess.check_output(["openssl","pkey","-in",str(tmp/"key.pem"),"-outform","DER"])
        (tmp/"key.raw").write_bytes(der[-32:]); (tmp/"key.raw").chmod(0o600)
        pub = subprocess.check_output(["openssl","pkey","-in",str(tmp/"key.pem"),"-pubout","-outform","DER"])
        (out/"trusted-public-key.raw").write_bytes(pub[-32:])
        config = tmp/"host.json"
        config.write_text(json.dumps({"version":1,"revision":"acceptance-1","deniedCapabilities":[]})); config.chmod(0o600)
        err = (out/"mcp.stderr.log").open("w")
        process = subprocess.Popen([str(binary),"mcp"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1,
            env=dict(os.environ,RIGHTCLICK_RCIR_CONFIG=str(config),RIGHTCLICK_EXPERIENCE="off"))
        advertise = subprocess.Popen(["dns-sd","-R",marker,"_rightclick._tcp","local",str(port),
                                     "kind=openapi","scheme=http","spec=/openapi.json","base=/"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        seq = 0
        def request(method, params):
            nonlocal seq
            seq += 1; query = {"jsonrpc":"2.0","id":seq,"method":method,"params":params}
            process.stdin.write(json.dumps(query)+"\n"); process.stdin.flush()
            selector = selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
            try:
                deadline = time.monotonic()+40
                while time.monotonic()<deadline:
                    if selector.select(max(0,deadline-time.monotonic())):
                        raw = process.stdout.readline()
                        if not raw: raise RuntimeError("MCP process ended")
                        answer = json.loads(raw)
                        if answer.get("id") == seq:
                            transcript.append({"request":query,"response":answer})
                            assert "error" not in answer, answer
                            return answer["result"]
                raise TimeoutError("MCP response")
            finally: selector.close()
        def call(name, arguments):
            result = request("tools/call",{"name":name,"arguments":arguments})
            assert not result.get("isError"), result
            return json.loads(result["content"][0]["text"])
        report = {"runKind":"NEW_RUN","binary":str(binary),"binarySHA256":hashlib.sha256(binary.read_bytes()).hexdigest(),"controls":{}}
        try:
            request("initialize",{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"rcir-production-acceptance","version":"1"}})
            tools = request("tools/list",{})["tools"]
            assert {t["name"] for t in tools} == TOOLS
            report["toolSchemaSHA256"] = hashlib.sha256(json.dumps(tools,sort_keys=True,separators=(",",":")).encode()).hexdigest()
            report["runtime"] = call("context_runtime",{})
            deadline = time.monotonic()+30; capability = None
            while time.monotonic()<deadline:
                found = call("context_actions",{"item":"disposable RCIR acceptance"})
                capability = next((a for a in found["actions"] if a.get("provider",{}).get("name") == marker),None)
                if capability: break
                time.sleep(.25)
            assert capability, "real Bonjour/OpenAPI capability not discovered"
            explained = call("context_explain",{"item":"disposable RCIR acceptance","actionId":capability["id"]})
            base = explained["metadata"]["baseURL"].rstrip("/")
            action = capability["id"]
            host = {"version":1,"revision":"acceptance-1","deniedCapabilities":[],"signingKeyFile":str(tmp/"key.raw"),
                "observers":{action:{"urlTemplate":base+"/records/{id}","expectedArgument":"value"}}}
            def configure(): config.write_text(json.dumps(host)); config.chmod(0o600)
            configure()
            def run(ident, confirmed=True, extra=None):
                arguments = {"item":"disposable RCIR acceptance","actionId":action,
                             "arguments":{"id":ident,"value":"useful verified output"},"confirmed":confirmed}
                if extra: arguments["arguments"].update(extra)
                return call("context_run",arguments)
            denied = run("confirmation",False)
            assert denied["state"] == "awaiting_user" and not effects
            report["controls"]["confirmation_zero_effect"] = "PASS"
            good = run("good")
            report["firstInvocation"] = good
            assert len(effects) == 1 and values["good"] == "useful verified output"
            assert good.get("rcir",{}).get("leaseConsumed") is True, "production invocation lacks mandatory RCIR admission/consumption"
            assert good["state"] == "succeeded" and good["rcir"]["outcome"] == "succeeded", good
            assert effects[-1]["correlationID"] == good["rcir"]["taskID"]
            status = call("context_run_status",{"executionId":good["executionId"]})
            assert status["rcir"] == good["rcir"] and status["state"] == good["state"]
            def receipt(record,label):
                envelope = record["rcir"]["signedReceipt"]
                (out/(label+"-receipt.json")).write_text(json.dumps(envelope,indent=2)+"\n")
                payload = base64.b64decode(envelope["payload"]); signature = base64.b64decode(envelope["signature"])
                assert envelope["publicKey"] == base64.b64encode(pub[-32:]).decode()
                (tmp/"payload").write_bytes(payload); (tmp/"signature").write_bytes(signature); (tmp/"pub.der").write_bytes(pub)
                subprocess.run(["openssl","pkeyutl","-verify","-pubin","-inkey",str(tmp/"pub.der"),"-keyform","DER","-rawin",
                                "-in",str(tmp/"payload"),"-sigfile",str(tmp/"signature")],check=True,stdout=subprocess.DEVNULL)
            receipt(good,"success")
            report["controls"]["verified_effect_and_pinned_signature"] = "PASS"
            repeat = run("repeat"); assert repeat["state"] == "succeeded"
            assert repeat["rcir"]["leaseID"] != good["rcir"]["leaseID"] and len(effects) == 2
            report["controls"]["separately_authorized_repeat_new_lease"] = "PASS"
            host["deniedCapabilities"] = [action]; configure(); denied = run("policy")
            assert denied["state"] in ("rejected","unavailable","failed") and len(effects) == 2
            report["controls"]["current_policy_zero_effect"] = "PASS"
            host["deniedCapabilities"] = []; configure()
            bad = run("argument",extra={"undeclared":"value"}); assert bad["state"] == "failed" and len(effects) == 2
            report["controls"]["schema_arguments_zero_effect"] = "PASS"
            mode["value"] = "wrong"; wrong = run("wrong")
            assert wrong["state"] == "failed" and wrong["rcir"]["outcome"] == "failed", wrong
            receipt(wrong,"failure")
            report["controls"]["provider_success_observed_mismatch_signed_failure"] = "PASS"
            mode["value"] = "missing"; missing = run("missing")
            assert missing["state"] == "accepted" and missing["rcir"]["outcome"] == "unverified", missing
            report["controls"]["missing_observation_unverified"] = "PASS"
            # Live schema changes while the discovered service/process stay alive.
            # No direct engine/library call or forced DNS-SD update performs this.
            mode["value"] = "correct"
            spec["info"]["version"] = "2"
            before = len(effects)
            old = run("stale-schema")
            assert len(effects) == before, "cached live specification drift reached the provider effect log"
            assert old["state"] in ("rejected", "unavailable", "failed"), old
            report["controls"]["live_cached_schema_drift_zero_effect"] = "PASS"
            new_catalog = call("context_actions", {"item":"disposable RCIR acceptance"})
            new_capability = next(a for a in new_catalog["actions"] if a.get("provider",{}).get("name") == marker)
            assert new_capability["id"] != action, "changed live specification did not reacquire a new contract"
            action = new_capability["id"]
            host["observers"] = {action:{"urlTemplate":base+"/records/{id}","expectedArgument":"value"}}
            host["revision"] = "acceptance-2"; configure()
            refreshed = run("refreshed-contract")
            assert refreshed["state"] == "succeeded" and len(effects) == before+1, refreshed
            report["controls"]["live_contract_reacquired_without_reconnection"] = "PASS"
            refreshed_tools = request("tools/list",{})["tools"]
            assert hashlib.sha256(json.dumps(refreshed_tools,sort_keys=True,separators=(",",":")).encode()).hexdigest() == report["toolSchemaSHA256"]
            report["controls"]["tool_schemas_unchanged_after_live_graph_change"] = "PASS"
            report["result"] = "PASS"
        except Exception as exc:
            report["result"] = "FAIL"; report["failure"] = str(exc)
            raise
        finally:
            (out/"transcript.json").write_text(json.dumps(transcript,indent=2)+"\n")
            (out/"results.json").write_text(json.dumps(report,indent=2)+"\n")
            advertise.terminate(); advertise.wait(timeout=5); process.terminate(); process.wait(timeout=5)
            server.shutdown(); err.close()
    print(json.dumps(report["controls"],indent=2))

if __name__ == "__main__": main()
