"""Engineering proof client; every provider action stays behind the same seven tools."""
import base64
import hashlib
import json
import os
import pathlib
import selectors
import subprocess
import time

TOOLS = {"context_runtime", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status", "context_providers"}


class Client:
    def __init__(self, binary, output, environment):
        self.binary = pathlib.Path(binary).resolve(); self.output = pathlib.Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True); self.transcript = []
        self.stderr = (self.output / "mcp.stderr.log").open("w")
        self.process = subprocess.Popen([str(self.binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, text=True, bufsize=1, env=dict(os.environ, **environment))
        self.request("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "rightclick-canonical-proof", "version": "1"}})
        self.tools = self.request("tools/list")["tools"]
        assert {t["name"] for t in self.tools} == TOOLS
        self.runtime = self.call("context_runtime", {})
        self.sha256 = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        assert self.runtime["executableSHA256"] == self.sha256

    def request(self, method, params=None):
        identity = len(self.transcript) + 1
        query = {"jsonrpc": "2.0", "id": identity, "method": method}
        if params is not None: query["params"] = params
        self.process.stdin.write(json.dumps(query) + "\n"); self.process.stdin.flush()
        selector = selectors.DefaultSelector(); selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            deadline = time.monotonic() + 55
            while time.monotonic() < deadline:
                if selector.select(max(0, deadline - time.monotonic())):
                    raw = self.process.stdout.readline()
                    if not raw: raise RuntimeError("MCP ended")
                    response = json.loads(raw)
                    if response.get("id") == identity:
                        self.transcript.append({"request": query, "response": response})
                        assert "error" not in response, response
                        return response["result"]
            raise TimeoutError("MCP response")
        finally: selector.close()

    def call(self, name, arguments):
        assert name in TOOLS
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])

    def close(self):
        (self.output / "transcript.json").write_text(json.dumps(self.transcript, indent=2))
        if self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=10)
            except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        self.stderr.close()


def signer(temporary, output):
    tmp, out = pathlib.Path(temporary), pathlib.Path(output)
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(tmp / "key.pem")], check=True, stdout=subprocess.DEVNULL)
    private = subprocess.check_output(["openssl", "pkey", "-in", str(tmp / "key.pem"), "-outform", "DER"])
    (tmp / "key.raw").write_bytes(private[-32:]); (tmp / "key.raw").chmod(0o600)
    trusted = subprocess.check_output(["openssl", "pkey", "-in", str(tmp / "key.pem"), "-pubout", "-outform", "DER"])
    (out / "trusted-public-key.raw").write_bytes(trusted[-32:]); (tmp / "trusted.der").write_bytes(trusted)
    return trusted[-32:]


def verify(record, temporary, output, trusted):
    tmp, out = pathlib.Path(temporary), pathlib.Path(output)
    envelope = record["rcir"]["signedReceipt"]
    assert base64.b64decode(envelope["publicKey"], validate=True) == trusted
    payload = base64.b64decode(envelope["payload"], validate=True)
    (out / "success-receipt.json").write_text(json.dumps(envelope, indent=2))
    (tmp / "receipt.raw").write_bytes(payload); (tmp / "signature.raw").write_bytes(base64.b64decode(envelope["signature"], validate=True))
    check = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(tmp / "trusted.der"), "-keyform", "DER", "-rawin",
        "-in", str(tmp / "receipt.raw"), "-sigfile", str(tmp / "signature.raw")], capture_output=True, text=True)
    assert check.returncode == 0, check.stderr
    return payload
