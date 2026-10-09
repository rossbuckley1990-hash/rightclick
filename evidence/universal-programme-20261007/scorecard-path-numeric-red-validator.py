#!/usr/bin/env python3
"""Validate evidence structure; --require-green enforces an acceptance prerequisite.

This does not certify a provider or an observation's truth. Independent acceptance
review must assess the referenced evidence before its status may be promoted.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

OPERATIONS = {
    "context_runtime", "context_providers", "context_inspect", "context_actions",
    "context_explain", "context_run", "context_run_status",
}
SUBSTRATES = {"macos", "windows", "linux", "openapi", "graphql", "grpc",
              "mcp", "a2a", "kafka", "kubernetes", "wasm"}
COLUMNS = {"acquisition", "common_abi", "authority", "policy", "execution",
           "async_stream", "independent_verification", "receipt", "withdrawal",
           "real_world_proof"}
REQUIRED_PROOFS = {"restricted_agent_acceptance", "independent_observation",
                   "receipt_verification", "withdrawal_proof", "stale_binding_denial"}
STREAM_WORLDS = {"grpc", "kafka", "kubernetes", "a2a"}
STAGE_ROLES = {
    "acquisition": {"restricted_agent_acceptance"}, "common_abi": {"restricted_agent_acceptance"},
    "authority": {"restricted_agent_acceptance"}, "policy": {"restricted_agent_acceptance"},
    "execution": {"restricted_agent_acceptance"}, "real_world_proof": {"restricted_agent_acceptance"},
    "async_stream": {"stream_lifecycle"}, "independent_verification": {"independent_observation"},
    "receipt": {"receipt_verification"}, "withdrawal": {"withdrawal_proof", "stale_binding_denial"},
}


class InvalidScorecard(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidScorecard(message)


def digest(value, size=64):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{%d}" % size, value) is not None


def strict_json(data):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON key: " + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise InvalidScorecard("nonfinite JSON number: " + value)

    try:
        return json.loads(data, object_pairs_hook=unique_pairs, parse_constant=invalid_constant)
    except (ValueError, TypeError) as error:
        raise InvalidScorecard("invalid evidence JSON: " + str(error)) from error


def evidence_reference(reference, root):
    require(isinstance(reference, dict), "evidence reference must be an object")
    path = reference.get("path")
    require(isinstance(path, str) and path and not Path(path).is_absolute(), "evidence path must be repository-relative")
    resolved = (root / path).resolve()
    require(resolved.is_relative_to(root.resolve()), "evidence path escapes the repository")
    require(resolved.is_file(), "missing evidence: " + path)
    expected = reference.get("sha256")
    require(digest(expected), "missing evidence SHA-256: " + path)
    data = resolved.read_bytes()
    require(hashlib.sha256(data).hexdigest() == expected, "evidence digest mismatch: " + path)
    # Consumers parse these exact checked bytes, never a second path lookup.
    return data


def reference_key(reference):
    return (reference.get("path"), reference.get("sha256"))


def same_identity(record, manifest):
    return all(record.get(field) == manifest[field] for field in ("source_commit", "binary_sha256", "session_id"))


def acceptance_proofs(manifest, scorecard, root):
    require(manifest.get("agent_kind") == "fresh_restricted_ai" and manifest.get("same_live_session") is True,
            "engineering drivers cannot replace the fresh same-session restricted AI proof")
    require(manifest.get("model_visible_operations") == scorecard["canonical_operations"] and
            type(manifest.get("provider_specific_tools_added")) is int and manifest["provider_specific_tools_added"] == 0,
            "acceptance tool catalogue differs from the canonical surface")
    require(isinstance(manifest.get("session_id"), str) and manifest["session_id"].strip(), "same-session identity required")
    require(digest(manifest.get("source_commit"), 40) and digest(manifest.get("binary_sha256")), "acceptance source/binary identities required")
    require(manifest["source_commit"] == scorecard["audited_candidate"], "acceptance source differs from the scorecard candidate")
    attestation = strict_json(evidence_reference(manifest.get("runtime_attestation"), root))
    require(isinstance(attestation, dict) and attestation.get("product") == "RIGHTCLICK" and
            attestation.get("executableSHA256") == manifest["binary_sha256"] and
            attestation.get("session_id") == manifest["session_id"], "serving-runtime attestation differs from acceptance")
    require(all(isinstance(attestation.get(field), str) and attestation[field].strip()
                for field in ("executablePath", "executableRealPath", "version")), "runtime path/version attestation required")
    provenance = strict_json(evidence_reference(manifest.get("binary_provenance"), root))
    require(isinstance(provenance, dict) and same_identity(provenance, manifest), "build provenance differs from acceptance")
    artifact = provenance.get("binary_artifact")
    evidence_reference(artifact, root)
    require(artifact["sha256"] == manifest["binary_sha256"], "accepted binary bytes differ from serving-runtime digest")
    proofs = manifest.get("proofs")
    require(isinstance(proofs, dict) and set(proofs) == SUBSTRATES, "acceptance manifest must prove every substrate")
    validated = {}
    for substrate, items in proofs.items():
        require(isinstance(items, list) and all(isinstance(item, dict) for item in items), "invalid substrate proofs")
        required = REQUIRED_PROOFS | ({"stream_lifecycle"} if substrate in STREAM_WORLDS else set())
        kinds = [item.get("kind") for item in items]
        require(all(isinstance(kind, str) for kind in kinds) and len(set(kinds)) == len(kinds) and
                required <= set(kinds), "missing or duplicate real acceptance evidence for " + substrate)
        report_paths = set()
        supporting_paths = set()
        validated[substrate] = {}
        for item in items:
            require(same_identity(item, manifest) and item.get("substrate") == substrate,
                    "proof does not belong to the accepted source/binary/session/world")
            require(item.get("real_environment") is True, "fixtures/builds/unit tests cannot establish real acceptance")
            report = strict_json(evidence_reference(item, root))
            require(isinstance(report, dict) and report.get("type") == "rightclick_universal_evidence_v1" and
                    report.get("kind") == item["kind"] and report.get("substrate") == substrate and
                    same_identity(report, manifest) and report.get("outcome") == "PASS", "proof report has a different role, identity or outcome")
            require(item["path"] not in report_paths, "different proof roles require distinct reports")
            report_paths.add(item["path"])
            artifacts = report.get("supporting_artifacts")
            require(isinstance(artifacts, list) and artifacts, "proof report requires supporting artifacts")
            paths = set()
            for reference in artifacts:
                evidence_reference(reference, root)
                require(reference["path"] not in paths and reference["path"] not in supporting_paths and
                        reference["path"] != item["path"], "different proof roles cannot reuse the same supporting artifact")
                paths.add(reference["path"])
            supporting_paths.update(paths)
            validated[substrate][item["kind"]] = reference_key(item)
    return validated


def validate(scorecard, root, require_green=False):
    require(isinstance(scorecard, dict) and scorecard.get("version") == 1, "unsupported scorecard version")
    operations = scorecard.get("canonical_operations")
    require(isinstance(operations, list) and len(operations) == 7 and set(operations) == OPERATIONS,
            "the AI surface must contain precisely the seven canonical operations")
    require(type(scorecard.get("provider_specific_top_level_tools_added")) is int and
            scorecard["provider_specific_top_level_tools_added"] == 0, "provider-specific AI operations are forbidden")
    require(digest(scorecard.get("objective_sha256")), "objective SHA-256 is required")
    require(digest(scorecard.get("main_source"), 40) and digest(scorecard.get("audited_candidate"), 40), "exact source identities are required")
    columns = scorecard.get("columns")
    require(isinstance(columns, list) and len(columns) == len(COLUMNS) and set(columns) == COLUMNS, "all completion columns are required")
    rows = scorecard.get("substrates")
    require(isinstance(rows, list) and len(rows) == 11 and all(isinstance(row, dict) for row in rows), "eleven substrate rows are required")
    require({row.get("id") for row in rows} == SUBSTRATES, "missing, duplicate or unknown substrate")
    experiment = scorecard.get("restricted_agent_experiment")
    require(isinstance(experiment, dict) and experiment.get("status") in {"RED", "GREEN"}, "experiment status required")
    for row in rows:
        require(row.get("status") in {"RED", "GREEN"}, "invalid row status")
        evidence_reference(row.get("implementation_reference"), root)
        for reference in row.get("supporting_evidence", []):
            evidence_reference(reference, root)
        stages = row.get("stages")
        require(isinstance(stages, dict) and set(stages) == COLUMNS, "incomplete stages for " + row["id"])
        for name, stage in stages.items():
            require(isinstance(stage, dict) and stage.get("status") in {"RED", "GREEN", "NOT_APPLICABLE"}, "invalid stage: " + name)
            require(isinstance(stage.get("evidence"), list), "stage evidence list required")
            for reference in stage["evidence"]:
                evidence_reference(reference, root)
            if stage["status"] == "NOT_APPLICABLE":
                require(name == "async_stream" and row["id"] not in STREAM_WORLDS and
                        isinstance(stage.get("reason"), str) and stage["reason"].strip(),
                        "only async/stream may be inapplicable with an explicit reason; required task/stream worlds cannot opt out")
            if stage["status"] == "GREEN":
                require(stage["evidence"], "GREEN stage without evidence")
                require(experiment["status"] == "GREEN", "stages cannot be GREEN before the restricted-agent experiment")
        if row["status"] == "GREEN":
            require(all(stage["status"] in {"GREEN", "NOT_APPLICABLE"} for stage in stages.values()), "GREEN row has incomplete stages")
        else:
            require(isinstance(row.get("remaining"), str) and row["remaining"].strip(), "RED row must state remaining work")
    if experiment["status"] == "GREEN":
        manifest = strict_json(evidence_reference(experiment.get("evidence"), root))
        require(isinstance(manifest, dict), "acceptance manifest must be an object")
        validated = acceptance_proofs(manifest, scorecard, root)
        for row in rows:
            for name, stage in row["stages"].items():
                if stage["status"] != "GREEN":
                    continue
                required = STAGE_ROLES[name]
                matches = {kind for kind, key in validated[row["id"]].items()
                           if any(reference_key(reference) == key for reference in stage["evidence"])}
                require(required <= matches, "GREEN stage is disconnected from its world and validated proof role: " + row["id"] + "/" + name)
        require(all(row["status"] == "GREEN" for row in rows), "GREEN experiment requires all eleven rows GREEN")
    if require_green:
        require(experiment["status"] == "GREEN" and all(row["status"] == "GREEN" for row in rows), "eleven-substrate acceptance remains RED")
    return {"status": experiment["status"], "substrates": len(rows), "operations": len(operations),
            "green_substrates": sum(row["status"] == "GREEN" for row in rows),
            "boundary": "Structural evidence gate; independent acceptance review remains mandatory."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scorecard", nargs="?", type=Path, default=Path("docs/universal-substrate-scorecard.json"))
    parser.add_argument("--require-green", action="store_true", help="fail unless all eleven real restricted-agent rows are GREEN")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        result = validate(strict_json(args.scorecard.read_bytes()), root, args.require_green)
    except (InvalidScorecard, OSError, ValueError, TypeError, KeyError) as error:
        print(json.dumps({"status": "INVALID_OR_INCOMPLETE", "error": str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
