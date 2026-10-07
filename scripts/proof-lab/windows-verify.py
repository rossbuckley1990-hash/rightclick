#!/usr/bin/env python3
"""Independent native Windows readiness observer; never prints credentials."""
import hashlib
import json
from pathlib import Path
import platform
import sys
import time
import urllib.error
import urllib.request
import uuid

config = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2])
origin = config["RIGHTCLICK_PROOF_HOST_ORIGIN"]
token = config["RIGHTCLICK_PROOF_HOST_TOKEN"]


def request(path, payload=None, credential=token):
    headers = {"Authorization": "Bearer " + credential, "Content-Type": "application/json"}
    data = None if payload is None else json.dumps(payload).encode()
    with urllib.request.urlopen(urllib.request.Request(origin + path, data=data, headers=headers), timeout=3) as result:
        return result.status, json.load(result)


for attempt in range(30):
    try:
        _, health = request("/health")
        break
    except OSError:
        time.sleep(1)
else:
    raise RuntimeError("native Windows service did not start")
assert platform.system() == health["platform"] == "Windows"
challenge = "rcproof_" + uuid.uuid4().hex
accepted, response = request("/proof", {"challenge": challenge})
assert accepted == 202 and response["accepted"] is True
effect = json.loads((Path(config["RIGHTCLICK_PROOF_EFFECTS"]) / (challenge + ".json")).read_text())
assert effect["platform"] == "Windows" and effect["principal"] == "rightclick-proof"
assert effect["result"] == hashlib.sha256(("RIGHTCLICK:" + challenge).encode()).hexdigest()
_, authority = request("/authority-check")
assert authority["protectedReadDenied"] is True
try:
    request("/proof", {"challenge": challenge + "_denied"}, credential="unavailable")
    raise AssertionError("unavailable host credential accepted")
except urllib.error.HTTPError as err:
    assert err.code == 401
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps({"acceptanceScope": "isolated native Windows infrastructure readiness only",
                          "nativeOS": platform.platform(), "health": health, "challenge": challenge,
                          "principal": effect["principal"], "acceptedHTTP": accepted,
                          "independentFileReadback": effect, "protectedAdministratorFileReadDenied": authority,
                          "unavailableCredentialHTTP": 401,
                          "credentialSource": "private ephemeral JSON configuration",
                          "credentialReference": sys.argv[1],
                          "sevenOperationRuntimeAcceptance": "RED: no unified live graph proof"}, indent=2))
print("Native Windows restricted-user effect and independent readback: PASS; protected file: DENIED")
