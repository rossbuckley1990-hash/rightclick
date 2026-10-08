"""Actual owned TLS/MCP fixture controls; no mocked serializer or TLS bypass."""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONFIG = """[req]
prompt=no
distinguished_name=subject
x509_extensions=v3
[subject]
CN=127.0.0.1
[v3]
subjectAltName=IP:127.0.0.1
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
"""


class PinnedTLSFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rightclick-owned-mcp-tls-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        config = self.directory / "tls.conf"
        config.write_text(CONFIG)
        self.command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", str(config),
                      "-keyout", str(self.directory / "tls-key.private"), "-out", str(self.directory / "certificate.pem")])
        self.token = "owned-disposable-token"
        (self.directory / "expected-token.private").write_text(self.token)
        (self.directory / "expected-token.private").chmod(0o600)
        (self.directory / "tls-key.private").chmod(0o600)

    def command(self, arguments):
        return subprocess.run(arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              check=True, timeout=10)

    def start(self):
        process = subprocess.Popen([sys.executable, str(ROOT / "Tests/Fixtures/mcp-admission-race.py"), str(self.directory)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def close():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        self.addCleanup(close)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll(), "Owned TLS fixture exited before atomic port publication")
            marker = self.directory / "port"
            if marker.exists():
                value = marker.read_text()
                if value.isdecimal() and 0 < int(value) <= 65535:
                    self.endpoint = "https://127.0.0.1:" + value + "/mcp"
                    return
            time.sleep(0.01)
        self.fail("Owned TLS fixture did not publish a valid port within unchanged bound")

    def call(self, *, url=None, certificate=None, token=None):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": "mutation", "arguments": {"challenge": "owned-actual-effect"}}}).encode()
        message = {"url": url or self.endpoint, "method": "POST",
                   "headers": {"Content-Type": "application/json", "Authorization": "Bearer " + (self.token if token is None else token)},
                   "body": base64.b64encode(body).decode()}
        return subprocess.run([sys.executable, str(ROOT / "Tests/Fixtures/mcp-pinned-tls-client.py"),
                               str(certificate or self.directory / "certificate.pem")], input=json.dumps(message).encode(),
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4, check=False)

    def effects(self):
        path = self.directory / "effects.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_pinned_tls_and_current_bearer_reach_one_actual_mcp_effect(self):
        self.start()
        result = self.call()
        self.assertEqual(result.returncode, 0)
        response = json.loads(result.stdout)
        self.assertEqual(response["status"], 200)
        self.assertEqual(json.loads(base64.b64decode(response["body"]))["result"]["structuredContent"], {"challenge": "owned-actual-effect"})
        self.assertEqual(self.effects(), [{"challenge": "owned-actual-effect", "changed": False}])

    def test_cleartext_origin_rejected_before_credential_or_effect(self):
        self.start()
        result = self.call(url=self.endpoint.replace("https://", "http://"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.effects(), [])

    def test_wrong_trusted_certificate_prevents_effect(self):
        self.start()
        other = self.directory / "other.pem"
        self.command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-config", str(self.directory / "tls.conf"),
                      "-keyout", str(self.directory / "other-key.private"), "-out", str(other)])
        (self.directory / "other-key.private").chmod(0o600)
        self.assertNotEqual(self.call(certificate=other).returncode, 0)
        self.assertEqual(self.effects(), [])

    def test_valid_owned_ca_cannot_substitute_a_different_leaf(self):
        pinned = self.directory / "pinned-original.pem"
        pinned.write_bytes((self.directory / "certificate.pem").read_bytes())
        self.command(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
                      "-keyout", str(self.directory / "child-key.private"), "-out", str(self.directory / "child.csr")])
        extension = self.directory / "leaf.conf"
        extension.write_text("subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")
        self.command(["openssl", "x509", "-req", "-in", str(self.directory / "child.csr"), "-CA", str(pinned),
                      "-CAkey", str(self.directory / "tls-key.private"), "-set_serial", "2", "-days", "1", "-extfile", str(extension),
                      "-out", str(self.directory / "certificate.pem")])
        (self.directory / "tls-key.private").write_bytes((self.directory / "child-key.private").read_bytes())
        (self.directory / "tls-key.private").chmod(0o600)
        self.start()
        self.assertNotEqual(self.call(certificate=pinned).returncode, 0)
        self.assertEqual(self.effects(), [])

    def test_server_refuses_wrong_bearer_without_effect(self):
        self.start()
        result = self.call(token="wrong-disposable-token")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["status"], 401)
        self.assertEqual(self.effects(), [])


if __name__ == "__main__":
    unittest.main()
