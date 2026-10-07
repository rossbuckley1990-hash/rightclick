#!/usr/bin/env python3
"""Compile actual production core without SwiftPM, MCP SDK or an MCP server.
Compare an existing direct entry, CLI and concrete MCP acceptance evidence.
Uses the already-authorised local returned-text regression, no external action.
"""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

from native_core_harness import host_file_arguments

root = pathlib.Path(__file__).resolve().parent.parent
binary = pathlib.Path(sys.argv[1]).resolve()
evidence = pathlib.Path(sys.argv[2]).resolve()
mcp_evidence = pathlib.Path(sys.argv[3]).resolve()
evidence.mkdir(parents=True, exist_ok=True)
sources = sorted((root / "Sources/RightClickCore").glob("*.swift"))
assert sources and all("import MCP" not in source.read_text() for source in sources)
harness = r'''
import Foundation
@main struct CoreAcceptance {
    static func main() throws {
        let engine = CapabilityRuntimeDefaults.makeEngine()
        let (_, actions) = try engine.capabilities(for: "RightClick")
        let unapproved = try engine.run(id: "AirDrop", item: "https://example.com/rightclick-policy", confirmed: false)
        let verified = try engine.run(id: "service:com.apple.ChineseTextConverterService:convertTextToFullWidth",
                                      item: "RightClick", confirmed: true, expectedOutput: "ＲｉｇｈｔＣｌｉｃｋ")
        let object: [String: Any] = [
            "actions": try JSONSerialization.jsonObject(with: Data(RightClickJSON.encode(actions).utf8)),
            "gated": try JSONSerialization.jsonObject(with: Data(RightClickJSON.encode(unapproved).utf8)),
            "verified": try JSONSerialization.jsonObject(with: Data(RightClickJSON.encode(verified).utf8))
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
'''
with tempfile.TemporaryDirectory(prefix="rightclick-neutral-core-") as directory:
    work = pathlib.Path(directory)
    entry = work / "Entry.swift"
    entry.write_text(harness)
    executable = work / "neutral-core"
    native_arguments, native_provenance = host_file_arguments(root, work, evidence)
    command = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
               "-whole-module-optimization", "-Onone",
               "-module-cache-path", str(work / "modules"), "-framework", "AppKit",
               *native_arguments, *map(str, sources), str(entry), "-o", str(executable)]
    compile_result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (evidence / "compile.txt").write_text(compile_result.stdout + compile_result.stderr)
    assert compile_result.returncode == 0, compile_result.stderr
    process = subprocess.run([str(executable)], capture_output=True, text=True, timeout=90)
    (evidence / "direct.stderr.txt").write_text(process.stderr)
    assert process.returncode == 0, process.stderr
    direct = json.loads(process.stdout)
    (evidence / "direct.json").write_text(json.dumps(direct, ensure_ascii=False, indent=2) + "\n")

cli_actions = json.loads(subprocess.check_output([str(binary), "actions", "RightClick", "--json"], text=True))
cli_verified = json.loads(subprocess.check_output([
    str(binary), "run", "service:com.apple.ChineseTextConverterService:convertTextToFullWidth",
    "RightClick", "--yes", "--expect-output", "ＲｉｇｈｔＣｌｉｃｋ", "--json"], text=True))
mcp = json.loads(mcp_evidence.read_text())
(evidence / "cli-actions.json").write_text(json.dumps(cli_actions, ensure_ascii=False, indent=2) + "\n")
(evidence / "cli-verified.json").write_text(json.dumps(cli_verified, ensure_ascii=False, indent=2) + "\n")
assert mcp["sha256"] == hashlib.sha256(binary.read_bytes()).hexdigest()

def contextual(rows, direct=False):
    return {row["id"]: (row["title"], row["source"], row.get("provider"),
                         row["inputs" if direct else "inputTypes"], row["safety"],
                         row["invocation"], row["requiresConfirmation"], row["supportLevel"])
            for row in rows}

def compare_catalogue(actual, label):
    expected = contextual(direct["actions"], True)
    observed = contextual(actual)
    differences = {identifier: {"direct": expected.get(identifier), label: observed.get(identifier)}
                   for identifier in sorted(expected.keys() | observed.keys())
                   if expected.get(identifier) != observed.get(identifier)}
    (evidence / (label + "-catalogue-differences.json")).write_text(
        json.dumps(differences, ensure_ascii=False, indent=2) + "\n")
    assert expected == observed, f"{label}: {len(differences)} contextual rows differ; see retained diagnostics"

assert direct["gated"]["status"] == "CONFIRMATION_REQUIRED"
assert direct["verified"]["status"] == cli_verified["status"] == "VERIFIED"
assert direct["verified"]["output"] == cli_verified["output"] == "ＲｉｇｈｔＣｌｉｃｋ"
assert direct["verified"]["evidence"] == cli_verified["evidence"]
compare_catalogue(cli_actions["actions"], "cli")
for index, record in enumerate(mcp["records"]):
    compare_catalogue(record["actions"]["actions"], f"mcp-{index}")
    assert record["confirmation"]["state"] == "awaiting_user"
    assert record["fullWidth"]["state"] == "succeeded"
    assert record["fullWidth"]["output"] == direct["verified"]["output"]
    assert record["fullWidth"]["evidence"] == direct["verified"]["evidence"]

result = {"direct": direct, "cliVerified": cli_verified,
          "equivalence": "PASS: contextual identity/types/support/policy and returned-text outcome evidence across direct, CLI, stdio and HTTP",
          "boundary": "Actual core sources compiled independently without MCP SDK or server. No hypothetical client support claimed.",
          "sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
          "nativeDependency": native_provenance,
          "candidateSHA256": mcp["sha256"]}
(evidence / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(result["equivalence"])
