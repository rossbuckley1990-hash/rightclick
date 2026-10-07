#!/usr/bin/env python3
"""Native setup control-flow regression with isolated synthetic configuration.

Compiles the actual RightClickSetup enum. Only its home-directory expression is
redirected to a temporary directory. Engine results are deterministic doubles;
this tests setup I/O and exit decisions, not native capability discovery.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source_path = root / "Sources/RightClickCLI/Setup.swift"
source = source_path.read_text()
setup = source[source.index("enum RightClickSetup {"):source.index("enum RightClickAuth {")]
setup = setup.replace(
    "FileManager.default.homeDirectoryForCurrentUser",
    'URL(fileURLWithPath: ProcessInfo.processInfo.environment["RIGHTCLICK_SETUP_TEST_HOME"]!)',
)
stubs = '''import Foundation
import Darwin
enum RightClickVersion { static let current = "0.1.0" }
enum RightClickJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
}
struct SetupDoctor {
    var macosVersion = "native-test"
    var serviceRegistrationCount = 1
    var actionExtensionCount = 0
    var sharingDiscovery = "PASS"
    var servicesDiscovery: String
}
struct SetupItem { var typeIdentifier: String? = "public.plain-text" }
enum SetupProbeError: Error { case expectedFailure }
struct CapabilityEngine {
    func doctor() -> SetupDoctor {
        SetupDoctor(servicesDiscovery: ProcessInfo.processInfo.environment["RIGHTCLICK_TEST_DISCOVERY"] ?? "PASS")
    }
    func providers() -> [Int] { [] }
    func inspect(_ text: String) throws -> SetupItem {
        if ProcessInfo.processInfo.environment["RIGHTCLICK_TEST_INSPECT"] == "FAIL" {
            throw SetupProbeError.expectedFailure
        }
        return SetupItem()
    }
}
'''
valid = {"theme": "preserve", "mcpServers": {"other": {"command": "/usr/bin/true", "args": []}}}
cases = [
    ("absent config", None, {}, True, False),
    ("valid config preserves others", json.dumps(valid), {}, True, False),
    ("array servers rejected intact", '{"mcpServers": ["preserve"]}', {}, False, True),
    ("string servers rejected intact", '{"mcpServers": "preserve"}', {}, False, True),
    ("null servers rejected intact", '{"mcpServers": null}', {}, False, True),
    ("non-object root rejected intact", '["preserve"]', {}, False, True),
    ("malformed JSON rejected intact", '{"preserve":', {}, False, True),
    ("inspection failure exits nonzero", json.dumps(valid), {"RIGHTCLICK_TEST_INSPECT": "FAIL"}, False, False),
    ("discovery failure exits nonzero", json.dumps(valid), {"RIGHTCLICK_TEST_DISCOVERY": "FAIL"}, False, False),
]
results = []
with tempfile.TemporaryDirectory(prefix="rightclick-native-setup-") as temporary:
    directory = pathlib.Path(temporary)
    swift = directory / "SetupControl.swift"
    binary = directory / "setup-control"
    swift.write_text(stubs + setup + '\nexit(Int32(RightClickSetup.run(json: CommandLine.arguments.contains("--json"))))\n')
    build = subprocess.run(["swiftc", "-module-cache-path", str(directory / "modules"),
                            str(swift), "-o", str(binary)], capture_output=True, text=True)
    if build.returncode:
        sys.stderr.write(build.stderr)
        sys.exit(build.returncode)
    for mode in ("json", "human"):
        for index, (name, content, extra, success, unchanged) in enumerate(cases):
            home = directory / f"home-{mode}-{index}"
            config = home / ".cursor/mcp.json"
            config.parent.mkdir(parents=True)
            if content is not None:
                config.write_text(content)
            environment = dict(os.environ, RIGHTCLICK_SETUP_TEST_HOME=str(home), **extra)
            command = [str(binary)] + (["--json"] if mode == "json" else [])
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
            checks = {"exit": (result.returncode == 0) == success}
            if unchanged:
                checks["input intact"] = config.read_text() == content
            else:
                updated = json.loads(config.read_text())
                checks["command exists"] = pathlib.Path(updated["mcpServers"]["rightclick"]["command"]).is_file()
                checks["arguments"] = updated["mcpServers"]["rightclick"]["args"] == ["mcp"]
                if content is not None:
                    checks["unrelated root preserved"] = updated["theme"] == valid["theme"]
                    checks["unrelated server preserved"] = updated["mcpServers"]["other"] == valid["mcpServers"]["other"]
            results.append({"case": name, "mode": mode, "passed": all(checks.values()), "checks": checks, "exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
report = {
    "scope": "Actual native setup enum with redirected temporary home and controlled engine doubles; not native capability acceptance",
    "sourceSha256": hashlib.sha256(source.encode()).hexdigest(),
    "compiler": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
    "passed": sum(case["passed"] for case in results),
    "failed": sum(not case["passed"] for case in results),
    "cases": results,
}
print(json.dumps(report, indent=2))
sys.exit(0 if report["failed"] == 0 else 1)
