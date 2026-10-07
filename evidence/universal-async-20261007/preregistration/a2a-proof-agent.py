#!/usr/bin/env python3
"""Disposable A2A 0.2.6 agent: genuine message/send and tasks/get lifecycle.

The agent writes a nonce-bound effect into a directory. A separate observer
process reads those bytes; task acceptance/artifacts do not choose the verifier.
"""
import argparse
import json
import pathlib
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--hold-until-file", action="store_true")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    effects = args.directory / "effects"
    effects.mkdir(exist_ok=True)
    tasks = {}
    lock = threading.Lock()

    def log(name, row):
        with lock:
            with (args.directory / name).open("a") as handle:
                handle.write(json.dumps(row, sort_keys=True) + "\n")

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, row, status=200):
            data = json.dumps(row, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path != "/.well-known/agent.json":
                return self.reply({"error": "not found"}, 404)
            self.reply({"protocolVersion": "0.2.6", "name": "RIGHTCLICK disposable delegated agent",
                        "description": "Persist one independently observable challenge", "version": "1.0.0",
                        "url": f"http://127.0.0.1:{self.server.server_port}/a2a",
                        "capabilities": {"streaming": False, "pushNotifications": False},
                        "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"],
                        "skills": [{"id": "persist-challenge", "name": "Persist challenge",
                                    "description": "Write one disposable nonce-bound result", "tags": ["proof"]}]})

        def do_POST(self):
            if self.path != "/a2a":
                return self.reply({"error": "not found"}, 404)
            try:
                count = int(self.headers.get("Content-Length", 0))
                if not 0 < count <= 65536:
                    raise ValueError("bounded request required")
                request = json.loads(self.rfile.read(count))
                identity = request["id"]
                if request["jsonrpc"] != "2.0":
                    raise ValueError("JSON-RPC 2.0 required")
                method, params = request["method"], request["params"]
                if method == "message/send":
                    message = params["message"]
                    text = message["parts"][0]["text"]
                    payload = json.loads(text)
                    challenge, value = payload["challenge"], payload["value"]
                    if not challenge or not challenge.isascii() or not all(c.isalnum() or c == "-" for c in challenge):
                        raise ValueError("safe nonce required")
                    task_id, context_id = str(uuid.uuid4()), str(uuid.uuid4())
                    task = {"kind": "task", "id": task_id, "contextId": context_id,
                            "status": {"state": "submitted"}}
                    with lock:
                        tasks[task_id] = task
                    log("requests.jsonl", {"method": method, "taskID": task_id, "challenge": challenge,
                                            "invocation": self.headers.get("X-RightClick-Invocation")})

                    def work():
                        if args.hold_until_file:
                            while not (args.directory / "release").exists():
                                time.sleep(0.01)
                        time.sleep(0.15)
                        with lock:
                            task["status"] = {"state": "working"}
                        time.sleep(0.35)
                        if value == "fail-task":
                            with lock:
                                task["status"] = {"state": "failed"}
                            return
                        if value != "missing-effect":
                            observed = "different" if value == "mismatch-effect" else value
                            (effects / challenge).write_text(observed)
                            log("effects.jsonl", {"taskID": task_id, "challenge": challenge, "value": observed})
                        with lock:
                            task["status"] = {"state": "completed"}
                            task["artifacts"] = [{"artifactId": "result", "parts": [{"kind": "text", "text": value}]}]
                    threading.Thread(target=work, daemon=True).start()
                    return self.reply({"jsonrpc": "2.0", "id": identity, "result": task})
                if method == "tasks/get":
                    with lock:
                        task = tasks.get(params["id"])
                        result = json.loads(json.dumps(task))
                    log("polls.jsonl", {"taskID": params["id"], "state": result["status"]["state"] if result else "not-found"})
                    if result is None:
                        return self.reply({"jsonrpc": "2.0", "id": identity, "error": {"code": -32001, "message": "Task not found"}})
                    return self.reply({"jsonrpc": "2.0", "id": identity, "result": result})
                return self.reply({"jsonrpc": "2.0", "id": identity, "error": {"code": -32601, "message": "Method not found"}})
            except (KeyError, ValueError, TypeError):
                self.reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32602, "message": "Invalid params"}})

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    (args.directory / "port").write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
