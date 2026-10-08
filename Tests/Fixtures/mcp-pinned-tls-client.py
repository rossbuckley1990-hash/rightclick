"""Test-owned TLS exchange; validates host/expiry/chain and exact fixture leaf.

No system trust mutation or insecure verification mode. The admitted request is
provided on stdin, never process arguments or persisted credential files.
"""
import base64
import http.client
import json
import pathlib
import ssl
import sys
import urllib.parse

certificate = pathlib.Path(sys.argv[1])
encoded = sys.stdin.buffer.read(1_048_577)
if len(encoded) > 1_048_576:
    raise ValueError("fixture_request_limit")
message = json.loads(encoded)
url = urllib.parse.urlsplit(message["url"])
if (url.scheme != "https" or url.hostname != "127.0.0.1"
        or url.username is not None or url.password is not None or url.fragment):
    raise ValueError("owned_fixture_origin_required")
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.load_verify_locations(cafile=certificate)
connection = http.client.HTTPSConnection(url.hostname, url.port, timeout=2,
                                         context=context)
try:
    connection.connect()
    expected = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    if connection.sock.getpeercert(binary_form=True) != expected:
        raise ValueError("owned_fixture_certificate_substitution")
    body = base64.b64decode(message["body"], validate=True)
    connection.request(message["method"], url.path + ("?" + url.query if url.query else ""),
                       body=body, headers=message["headers"])
    response = connection.getresponse()
    data = response.read(1_048_577)
    if len(data) > 1_048_576:
        raise ValueError("fixture_response_limit")
    # http.client does not follow redirects or retain ambient credentials.
    print(json.dumps({"status": response.status, "headers": dict(response.getheaders()),
                      "body": base64.b64encode(data).decode()}))
finally:
    connection.close()
