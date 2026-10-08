#!/usr/bin/env python3
"""Reject missing, failed or skipped provisioned XCTest identities.

This narrow fixture gate supplements, and never replaces, the full input-test
identity union gate. Expected cases come from the actual selected source files.
"""
import argparse
import json
import pathlib
import re


def identity(raw):
    if raw.startswith("-[") and raw.endswith("]"):
        owner, method = raw[2:-1].split(" ", 1)
        return owner.rsplit(".", 1)[-1] + "/" + method
    owner, method = raw.rsplit(".", 1)
    return owner.rsplit(".", 1)[-1] + "/" + method


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--require-class", action="append", default=[])
    parser.add_argument("--allow-skip", action="append", default=[])
    parser.add_argument("--not-compiled", action="append", default=[],
                        help="Exact reviewed source-only conditional identity on this host")
    args = parser.parse_args()
    expected = set()
    errors = []
    for owner in args.require_class:
        files = list((args.repo / "Tests").rglob(owner + ".swift"))
        if len(files) != 1:
            errors.append("Expected one source for " + owner)
            continue
        source = files[0].read_text()
        methods = re.findall(r"\bfunc\s+(test\w+)\s*\(", source)
        if not methods or len(methods) != len(set(methods)):
            errors.append("Missing or duplicate source test methods for " + owner)
        expected.update(owner + "/" + method for method in methods)
    if not expected:
        errors.append("No required provisioned test identities")
    outcomes = {}
    log = args.log.read_text(errors="replace")
    for raw, outcome in re.findall(r"Test Case '([^']+)' (passed|failed|skipped)(?: \(| at )", log):
        try:
            key = identity(raw)
        except ValueError:
            errors.append("Unrecognized completed XCTest identity")
            continue
        if key in outcomes:
            errors.append("Repeated completed test identity: " + key)
        outcomes[key] = outcome
    permitted = set(args.allow_skip)
    excluded = set(args.not_compiled)
    if not excluded.issubset(expected):
        errors.append("Conditional source exception contains an unexpected identity")
    if any(key in outcomes for key in excluded):
        errors.append("A source-only exception unexpectedly appears in executable outcomes")
    expected -= excluded
    if not permitted.issubset(expected):
        errors.append("Skip allowlist contains an unexpected identity")
    for key in sorted(expected):
        outcome = outcomes.get(key)
        if outcome != "passed" and not (outcome == "skipped" and key in permitted):
            errors.append(key + ": " + (outcome or "not completed"))
    if any(value == "failed" for value in outcomes.values()):
        errors.append("A selected test failed")
    if not re.search(r"Test Suite 'Selected tests' passed at ", log):
        errors.append("Selected test suite did not complete")
    report = {"schemaVersion": 1, "scope": "actual provisioned XCTest identities",
              "required": sorted(expected), "allowSkip": sorted(permitted), "notCompiled": sorted(excluded),
              "outcomes": dict(sorted(outcomes.items())), "errors": sorted(set(errors)),
              "status": "PASS" if not errors else "FAIL"}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print("Fixture outcome gate:", report["status"], "required", len(expected))
    for error in report["errors"]:
        print(error)
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
