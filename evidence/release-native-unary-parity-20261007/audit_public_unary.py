#!/usr/bin/env python3
"""Independently audit frozen public unary compatibility artifacts only."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re

NAMES = {"context_runtime", "context_providers", "context_inspect", "context_actions",
         "context_explain", "context_run", "context_run_status"}
DESCRIPTOR = "bc30e6f198e9bfae8008065a15a038538033c5b87adcf2322ddf3a9f1eda6b04"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    return json.loads(path.read_text())


def digest(path):
    data = path.read_bytes()
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def audit(directory, binary, version):
    tools = load(directory / "tools.json")["tools"]
    require(len(tools) == 7 and {t["name"] for t in tools} == NAMES,
            "catalogue is not exactly the canonical seven operations")
    exchanges = load(directory / "exchanges.json")
    require(all(row["operation"] in NAMES for row in exchanges), "unexpected operation")
    select = lambda name: [row["response"] for row in exchanges if row["operation"] == name]
    runtime_rows = select("context_runtime")
    require(len(runtime_rows) == 1, "expected one runtime provenance read")
    runtime = runtime_rows[0]
    binary_hash = digest(binary)["sha256"]
    require(runtime["product"] == "RIGHTCLICK" and runtime["transport"] == "stdio",
            "wrong product or transport")
    require(runtime["version"] == version and runtime["executableSHA256"] == binary_hash,
            "runtime provenance differs from the supplied binary")
    require(Path(runtime["executableRealPath"]).resolve() == binary.resolve(),
            "runtime real path differs from the supplied binary")
    require(type(runtime["pid"]) is int and runtime["pid"] > 0, "invalid runtime PID")
    capability = load(directory / "capability.json")
    require(capability["title"] == "gRPC rightclick.pressure.Streams/Echo" and
            capability["invocation"] == "interactive" and
            capability["requiresConfirmation"] is True, "wrong unary capability")
    require("metadata" not in capability, "legacy public capability shape unexpectedly changed")
    actions = select("context_actions")
    require(any(any(row == capability for row in response["actions"]) for response in actions),
            "selected capability absent from the actual discovery reply")
    explanation_rows = select("context_explain")
    require(len(explanation_rows) == 1, "expected one explanation")
    explanation = explanation_rows[0]
    metadata = explanation["metadata"]
    require(explanation["id"] == capability["id"] and
            metadata["callType"] == "unary" and
            metadata["rpcPath"] == "/rightclick.pressure.Streams/Echo" and
            metadata["descriptorSHA256"] == DESCRIPTOR and
            metadata["substrate"] == "grpc", "wrong reflected unary contract")
    advertisement = (directory / "advertisement.log").read_text()
    require("Using LocalOnly" in advertisement and "Name now registered and active" in advertisement,
            "actual local-only DNS-SD registration evidence absent")
    require(capability["provider"]["name"] in advertisement,
            "capability provider differs from the announced owned service")
    runs = select("context_run")
    require(len(runs) == 2 and runs[0]["state"] == "awaiting_user",
            "expected gated invocation then confirmed invocation")
    require(all(row["actionId"] == capability["id"] for row in runs), "wrong invoked capability")
    journal_path = directory / "stream-events.jsonl"
    raw_journal = journal_path.read_bytes() if journal_path.exists() else b""
    require(not raw_journal or raw_journal.endswith(b"\n"), "incomplete native journal row")
    journal = [json.loads(line) for line in raw_journal.splitlines()]
    report = {"runtime": runtime, "independentlyHashedBinary": binary_hash,
              "catalogueCount": 7, "operationsObserved": sorted({row["operation"] for row in exchanges}),
              "descriptorSHA256": metadata["descriptorSHA256"], "discoveredUnaryTitle": capability["title"],
              "confirmedState": runs[1]["state"], "nativeCallCount": len(journal),
              "inputHashes": {str(path): digest(path) for path in
                  [directory / "tools.json", directory / "exchanges.json", directory / "capability.json",
                   directory / "advertisement.log"]}}
    if runs[1]["state"] == "rejected":
        require(len(journal) == 0, "rejected invocation produced a native call")
        require(not list(directory.glob("echo-parity-*.txt")), "rejected invocation produced a file effect")
        report.update(audit="PRE_DISPATCH_REJECTION", error=runs[1]["message"],
                      evidence=runs[1]["evidence"], nativeFileEffect=False,
                      retainedSuccessfulOutput=False, runtimeRegressionEstablished=False)
        return report, tools, explanation
    require({row["operation"] for row in exchanges} == NAMES, "not all seven operations exercised")
    require(len(journal) == 1 and journal[0]["kind"] == "unary", "expected exactly one native unary call")
    challenge = journal[0]["challenge"]
    require(isinstance(challenge, str) and re.fullmatch(r"parity-[0-9a-f]{32}", challenge),
            "native request challenge is not the bounded owned challenge")
    effect = directory / ("echo-" + challenge + ".txt")
    require(not effect.is_symlink() and effect.resolve().parent == directory.resolve(), "effect escaped owned directory")
    require(effect.read_bytes() == challenge.encode(), "owned external file differs from native request")
    result = runs[1]
    require(result["state"] == "accepted", "legacy unary should remain accepted without an outcome observer")
    require(json.loads(result["output"]) == {"value": challenge}, "returned JSON differs from native request")
    require(result["evidence"]["outcomeVerified"] is False, "runtime promotes acceptance to verified truth")
    status_rows = select("context_run_status")
    require(len(status_rows) == 1 and status_rows[0] == result, "retained status differs from the full original result")
    records = load(directory / "runtime-records.json")
    require(records == [result, status_rows[0]], "exported records differ from actual public responses")
    require(not (directory / "observations.jsonl").exists(), "unexpected stream observation evidence")
    report.update(audit="PASS", nativeFileEffect=True, requestChallenge=challenge,
                  exactReturnedJSON=True, retainedFullResultEqual=True, semanticOutcomeVerified=False,
                  nativeMarker=journal[0].get("invocation"),
                  gatingTemporalScope="awaiting_user reply plus one total call; pre-confirmation zero-call timing is a separate harness assertion",
                  externalTruth="exact owned file and native request correspondence; runtime acceptance alone does not establish truth")
    report["inputHashes"].update({str(p): digest(p) for p in
        [journal_path, effect, directory / "runtime-records.json"]})
    return report, tools, explanation


def compare_tools(old, new):
    old_by_name = {row["name"]: row for row in old}
    new_by_name = {row["name"]: row for row in new}
    require([row["name"] for row in old] == [row["name"] for row in new], "tool ordering changed")
    differences = []
    for name in NAMES:
        if old_by_name[name] == new_by_name[name]:
            continue
        modified = copy.deepcopy(new_by_name[name])
        require(name == "context_run", "unexpected changed public tool")
        schema = modified["inputSchema"]
        require("contractSHA256" not in schema.get("required", []), "new contract pin became required")
        pin = schema["properties"].pop("contractSHA256")
        require(pin["type"] == "string", "unexpected contract pin type")
        require(modified == old_by_name[name], "legacy tool shape differs beyond the optional pin")
        differences.append({"tool": name, "change": "optional contractSHA256 string property only"})
    return {"audit": "PASS", "canonicalNamesAndOrderEqual": True,
            "legacyPropertiesAndRequiredFieldsEqual": True, "differences": differences}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline-binary", type=Path, required=True)
    parser.add_argument("--candidate-binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline, old_tools, old_explain = audit(args.baseline, args.baseline_binary, "0.2.2")
    candidate, new_tools, new_explain = audit(args.candidate, args.candidate_binary, "0.2.3")
    catalogue = compare_tools(old_tools, new_tools)
    fields = ["argumentsSchema", "callType", "descriptorSHA256", "method", "requestType",
              "responseType", "resultValidation", "rpcPath", "service", "substrate"]
    require(all(old_explain["metadata"][key] == new_explain["metadata"][key] for key in fields),
            "unary reflected contract changed")
    result = {"audit": "PASS" if candidate["audit"] == "PASS" else "CANDIDATE_SETUP_REJECTION",
              "baseline": baseline, "candidate": candidate, "publicCatalogueCompatibility": catalogue,
              "unaryReflectedContractEqual": True,
              "excluded": ["new stream support", "issuer authentication or authority proof", "fresh restricted AI",
                           "all eleven substrates", "shipping or publication"]}
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"audit": result["audit"], "output": str(args.output),
                      "baseline": baseline["audit"], "candidate": candidate["audit"]}))


if __name__ == "__main__":
    main()
