#!/usr/bin/env python3
"""Private native Linux provider/observer; never installed as a runtime adapter."""
import hashlib
import http.server
import json
import os
import pathlib
import sys
import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

NAME = "org.rightclick.Pressure"
PATH = "/org/rightclick/Pressure"
INTERFACE = "org.rightclick.Pressure"
root = pathlib.Path(sys.argv[1]); role = sys.argv[2]
DBusGMainLoop(set_as_default=True)
bus = dbus.bus.BusConnection("unix:path=" + str(root / "bus"))

def valid(challenge):
    return len(challenge) == 32 and all(c in "0123456789abcdef" for c in challenge)

if role == "service":
    name = dbus.service.BusName(NAME, bus=bus, do_not_queue=True)
    class Provider(dbus.service.Object):
        @dbus.service.method(INTERFACE, in_signature="ssbs", out_signature="s", sender_keyword="sender")
        def Store(self, challenge, value, enabled, invocation, sender):
            if not valid(challenge): raise dbus.exceptions.DBusException("Invalid challenge")
            uid = int(bus.get_unix_user(sender))
            with (root / "state" / "effects.jsonl").open("a") as log:
                log.write(json.dumps({"challenge": str(challenge), "writerUID": uid, "enabled": bool(enabled), "sender": sender, "owner": bus.get_unique_name()}) + "\n")
            if not (root / "no-effect").exists():
                record = {"challenge": str(challenge), "value": str(value), "enabled": bool(enabled), "writerUID": str(uid), "invocation": str(invocation)}
                (root / "records" / str(challenge)).write_text(json.dumps(record))
            return "accepted"

        @dbus.service.method(INTERFACE, in_signature="s", out_signature="ss")
        def GetProof(self, challenge):
            if not valid(challenge): raise dbus.exceptions.DBusException("Invalid challenge")
            record = json.loads((root / "records" / str(challenge)).read_text())
            return str(record["challenge"]), hashlib.sha256(record["value"].encode()).hexdigest()

        @dbus.service.method(INTERFACE, in_signature="v", out_signature="v")
        def UnsupportedVariant(self, value): return value

        @dbus.service.method(INTERFACE, in_signature="as", out_signature="as")
        def EchoTags(self, values): return values

        @dbus.service.method(INTERFACE, in_signature="", out_signature="")
        def Acknowledge(self): pass

    provider = Provider(bus, PATH)
    (root / "state" / "service-ready").write_text(bus.get_unique_name())
    def release_if_requested():
        if (root / "release-name").exists() and not (root / "state" / "service-released").exists():
            bus.release_name(NAME)
            (root / "state" / "service-released").write_text(bus.get_unique_name())
        return True
    GLib.timeout_add(20, release_if_requested)
    GLib.MainLoop().run()
elif role == "observer":
    token = (root / "observer.token").read_text()
    class Observer(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403); return
            challenge = self.path.removeprefix("/observations/")
            if not self.path.startswith("/observations/") or not valid(challenge): self.send_error(400); return
            try:
                # Exercise the genuinely read-only D-Bus principal, then read
                # stored bytes independently and compute the digest ourselves.
                proxy = bus.get_object(NAME, PATH, introspect=False)
                acquired, provider_digest = proxy.GetProof(challenge, dbus_interface=INTERFACE)
                record = json.loads((root / "records" / challenge).read_text())
                digest = hashlib.sha256(record["value"].encode()).hexdigest()
                assert str(acquired) == challenge and str(provider_digest) == digest
                result = {"challenge": challenge, "digest": digest, "writerUID": record["writerUID"],
                    "observerUID": str(os.geteuid()), "platform": "Linux", "observation": "independent-file-sha256", "enabled": "true" if record["enabled"] else "false", "invocation": record["invocation"]}
                with (root / "observer-state" / "observations.jsonl").open("a") as log:
                    log.write(json.dumps(dict(result, invocation=self.headers.get("X-RightClick-Invocation"))) + "\n")
                body = json.dumps(result).encode()
                self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            except Exception: self.send_error(404)
    server = http.server.HTTPServer(("127.0.0.1", 0), Observer)
    (root / "observer-state" / "port").write_text(str(server.server_port))
    server.serve_forever()
