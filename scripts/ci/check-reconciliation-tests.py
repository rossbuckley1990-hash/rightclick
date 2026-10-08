#!/usr/bin/env python3
"""Fail closed on lost tests, outcome regressions, and incomplete XCTest evidence.

The immutable manifests record observations at the two input heads, not claims
about the integrated candidate. Source accounting is additional evidence; only
discovered, completed XCTest cases count as executed tests.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
from pathlib import Path
import platform as host_platform
import re
import sys

HEADS = {"pr49": "053b6202df504ff1a33682a39f2e72a959f65983",
         "pr99": "6a18aaae3ae3a15b9f6c78f189adc695ae11585a"}
MODULES = {"RightClickARDTests", "RightClickCLITests", "RightClickCoreTests",
           "RightClickMCPTests", "RightClickLinkTests", "RightClickProtocolTests",
           "RightClickProvidersTests", "RightClickMacOSTests", "RightClickLinuxTests"}
IDENTIFIER = r"[A-Za-z_][A-Za-z0-9_]*"
IDENTITY = re.compile(rf"^({IDENTIFIER})\.(test[A-Za-z0-9_]*)$")
ALLOWED_RENAME = ("PolicyTests.testDedupeKeepsFirstIdentifier",
                  "PolicyTests.testDedupeQuarantinesConflictingIdentity")
# Filled from exact-head artifact conversion. Changing these pins requires review.
MANIFEST_HASHES = {'baseline-linux-arm64.json': 'b4442d30fa49ff36fe769d8938cea443166a8d06b27f52cfa930779ff1810c90', 'baseline-linux-x86_64.json': 'b0245630fc603ab14183e0cd5fd189d46c5c4b0cf3c517233f3239d5e571a649', 'baseline-macos-arm64.json': '9004566badca16ec510e64a17d6d4d81bbd04b0bbf179b123bdd77837676667e', 'reviewed-test-mappings.json': '3a1df9dd846797c137080cd2308644694e2ae0a7060df83313f37d36e12a7c65', 'source-test-baseline.json': '793c753fa4acf332a1e21a81b9c921928572ea736a3a3f80aa3b19f3be768a9f'}
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
CASE = re.compile(r"^Test Case '([^']+)' (started|passed|failed|skipped)(?:\.| at .*| \([0-9.]+ seconds\)\.?)$")
SUITE = re.compile(r"^Test Suite '([^']+)' (started|passed|failed) at .+$")
SUMMARY = re.compile(r"^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\) in [0-9.]+(?: \([0-9.]+\))? seconds\.?$")


class EvidenceError(ValueError):
    pass


def read_json(path: Path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise EvidenceError(f"Duplicate JSON key {key!r} in {path.name}")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def normalize(raw: str) -> tuple[str, str | None]:
    """Only strip known XCTest display wrappers and known test module prefixes."""
    if raw.startswith("-["):
        match = re.fullmatch(r"-\[([^ ]+) (test[A-Za-z0-9_]*)\]", raw)
        if not match:
            raise EvidenceError(f"Malformed XCTest identity: {raw!r}")
        raw = match[1] + "." + match[2]
    elif "/" in raw:
        match = re.fullmatch(rf"({IDENTIFIER}\.{IDENTIFIER})/(test[A-Za-z0-9_]*)(?:\(\))?", raw)
        if not match:
            raise EvidenceError(f"Malformed discovery identity: {raw!r}")
        raw = match[1] + "." + match[2]
    parts = raw.split(".")
    module = None
    if len(parts) == 3:
        module = parts.pop(0)
        if module not in MODULES:
            raise EvidenceError(f"Unknown test module: {module!r}")
    identity = ".".join(parts)
    if not IDENTITY.fullmatch(identity):
        raise EvidenceError(f"Malformed test identity: {raw!r}")
    return identity, module


def parse_discovery(text: str) -> dict[str, str | None]:
    result = {}
    for number, original in enumerate(text.splitlines(), 1):
        line = ANSI.sub("", original).strip()
        if not line:
            continue
        # swift test list stdout contains qualified Class/method entries.
        # stderr may contain compiler/build diagnostics. Never ignore a line
        # resembling a malformed discovery entry.
        resembles_entry = (re.match(rf"^(?:{IDENTIFIER}\.)?{IDENTIFIER}/", line)
                           or re.match(rf"^(?:{IDENTIFIER}\.)?{IDENTIFIER}\.test", line)
                           or any(line.startswith(module + ".") and "/" in line for module in MODULES))
        if not resembles_entry:
            continue
        identity, module = normalize(line)
        if identity in result:
            raise EvidenceError(f"Duplicate/colliding discovery identity: {identity}")
        result[identity] = module
    if not result:
        raise EvidenceError("No test identities discovered")
    return result


def parse_log(text: str, scope: str = "full") -> dict:
    expected_root = "All tests" if scope == "full" else "Selected tests"
    stack = []
    pending_summary = None
    starts, outcomes = {}, {}
    root_summary = None
    root_count = 0
    events = []
    for number, original in enumerate(text.splitlines(), 1):
        line = ANSI.sub("", original).strip()
        if not line:
            continue
        if "error: Exited with unexpected signal code" in line:
            raise EvidenceError(f"Test process crashed on line {number}")
        suite_match = SUITE.fullmatch(line)
        case_match = CASE.fullmatch(line)
        summary_match = SUMMARY.fullmatch(line)
        if pending_summary is not None:
            if not summary_match:
                raise EvidenceError(f"Missing summary for suite {pending_summary['name']!r} on line {number}")
            total, skipped, failures, unexpected = [int(value or 0) for value in summary_match.groups()]
            counts = pending_summary["counts"]
            if total != sum(counts.values()) or skipped != counts["skipped"]:
                raise EvidenceError(f"Summary/case discrepancy for suite {pending_summary['name']!r}")
            if failures or unexpected or pending_summary["status"] != "passed" or counts["failed"]:
                raise EvidenceError(f"Failed suite {pending_summary['name']!r}: {failures} failures, {unexpected} unexpected")
            if pending_summary["name"] == expected_root:
                root_summary = {"total": total, "skipped": skipped,
                                "assertionFailures": failures, "unexpected": unexpected}
            pending_summary = None
            continue
        if suite_match:
            name, status = suite_match.groups()
            if status == "started":
                if not stack:
                    if name != expected_root:
                        raise EvidenceError(f"Expected {expected_root!r}, found root {name!r}")
                    root_count += 1
                    if root_count != 1:
                        raise EvidenceError("Multiple test runs in one evidence log")
                stack.append({"name": name, "counts": collections.Counter()})
            else:
                if not stack or stack[-1]["name"] != name:
                    raise EvidenceError(f"Unmatched suite completion: {name!r}")
                pending_summary = stack.pop()
                pending_summary["status"] = status
            continue
        if summary_match:
            raise EvidenceError(f"Summary without suite completion on line {number}")
        if case_match:
            if not stack:
                raise EvidenceError(f"Case outside active suite on line {number}")
            raw, state = case_match.groups()
            identity, module = normalize(raw)
            if state == "started":
                if identity in starts:
                    raise EvidenceError(f"Duplicate/colliding case start: {identity}")
                starts[identity] = module
            else:
                if identity not in starts or identity in outcomes:
                    raise EvidenceError(f"Unmatched/duplicate case completion: {identity}")
                if starts[identity] != module:
                    raise EvidenceError(f"Case module changed during execution: {identity}")
                outcomes[identity] = {"outcome": state, "module": module}
                for suite in stack:
                    suite["counts"][state] += 1
                events.append(identity)
            continue
        if line.startswith("Test Case ") or line.startswith("Test Suite "):
            raise EvidenceError(f"Malformed XCTest event on line {number}")
        if line.startswith("✔ Test run with ") and not re.match(r"✔ Test run with 0 tests in 0 suites passed", line):
            raise EvidenceError("Additional Swift Testing cases require an explicit parser; they cannot be omitted")
    if stack or pending_summary or root_summary is None or root_count != 1:
        raise EvidenceError("Incomplete XCTest run: no complete root suite and matching summary")
    if set(starts) != set(outcomes):
        raise EvidenceError("Incomplete test cases: " + ", ".join(sorted(set(starts) - set(outcomes))))
    if not outcomes:
        raise EvidenceError("No completed test cases")
    return {"outcomes": outcomes, "summary": root_summary}


def strip_swift_literals(text: str) -> str:
    """Small lexical scanner for source accounting; it is not a Swift compiler."""
    result = list(text)
    index = 0
    while index < len(text):
        start, end = index, None
        if text.startswith("//", index):
            end = text.find("\n", index)
            if end < 0:
                end = len(text)
        elif text.startswith("/*", index):
            depth, end = 1, index + 2
            while end < len(text) and depth:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            if depth:
                raise EvidenceError("Unterminated Swift comment in source inventory")
        else:
            match = re.match(r'(#+)?("""|")', text[index:])
            if match:
                hashes, quote = match[1] or "", match[2]
                delimiter, end = quote + hashes, index + len(match[0])
                while end < len(text):
                    if text.startswith(delimiter, end):
                        end += len(delimiter)
                        break
                    if not hashes and text[end] == "\\":
                        end += 2
                    else:
                        end += 1
                else:
                    raise EvidenceError("Unterminated Swift literal in source inventory")
        if end is not None:
            for position in range(start, min(end, len(text))):
                if result[position] != "\n":
                    result[position] = " "
            index = end
        else:
            index += 1
    return "".join(result)


def source_declarations(text: str) -> list[str]:
    clean = strip_swift_literals(text)
    token = re.compile(rf"\b(class|struct|enum|extension|func)\s+({IDENTIFIER})|[{{}}]")
    stack, pending, declarations = [], None, []
    for match in token.finditer(clean):
        value = match[0]
        if match[1]:
            kind, name = match[1], match[2]
            if kind == "func" and name.startswith("test"):
                owner = next((scope[1] for scope in reversed(stack) if scope and scope[0] in {"class", "extension"}), None)
                if owner and not any(scope and scope[0] == "func" for scope in stack):
                    declarations.append(owner + "." + name)
            pending = (kind, name)
        elif value == "{":
            stack.append(pending)
            pending = None
        else:
            if not stack:
                raise EvidenceError("Unbalanced Swift source braces in inventory")
            stack.pop()
            pending = None
    if stack:
        raise EvidenceError("Unbalanced Swift source braces in inventory")
    return declarations


def source_inventory(root: Path) -> dict[str, list[str]]:
    if not root.is_dir():
        raise EvidenceError(f"Missing source test directory: {root}")
    result = {}
    for path in sorted(root.rglob("*.swift")):
        if path.is_symlink():
            raise EvidenceError(f"Symlinked test source: {path}")
        for identity in source_declarations(path.read_text(encoding="utf-8")):
            result.setdefault(identity, []).append(str(path.relative_to(root)))
    return result


def mapping_document(document: dict, platform: str) -> dict[str, str]:
    if document.get("schemaVersion") != 1 or document.get("sourceHeads") != HEADS:
        raise EvidenceError("Invalid mapping identity/version")
    rows = document.get("renames")
    if not isinstance(rows, list) or len(rows) != 1:
        raise EvidenceError("Exactly the reviewed Policy rename is permitted")
    row = rows[0]
    if (row.get("from"), row.get("to")) != ALLOWED_RENAME or not row.get("reason"):
        raise EvidenceError("Unreviewed test rename")
    if row.get("platforms") != ["macos-arm64", "linux-x86_64", "linux-arm64"]:
        raise EvidenceError("Invalid mapping platform scope")
    return {row["from"]: row["to"]}


def validate(baseline: dict, discovery: dict, run: dict, mappings: dict,
             source_baseline: dict | None = None, sources: dict | None = None,
             require_pass: list[str] | None = None, selection: str | None = None) -> dict:
    if baseline.get("schemaVersion") != 1 or baseline.get("sourceHeads") != HEADS:
        raise EvidenceError("Invalid immutable baseline identity/version")
    rows = baseline.get("tests")
    if not isinstance(rows, list) or len(rows) != baseline.get("identityCount"):
        raise EvidenceError("Invalid immutable baseline count")
    baseline_tests, mapped = {}, {}
    for row in rows:
        if not isinstance(row, list) or len(row) != 3:
            raise EvidenceError("Malformed baseline test row")
        identity, pr99, pr49 = row
        if not isinstance(identity, str) or not IDENTITY.fullmatch(identity) or identity in baseline_tests:
            raise EvidenceError("Duplicate/malformed baseline identity")
        if any(value not in {None, "passed", "skipped", "failed"} for value in [pr99, pr49]) or pr99 is None and pr49 is None:
            raise EvidenceError("Invalid baseline observation")
        target = mappings.get(identity, identity)
        if target in mapped:
            originals = set(mapped[target]) | {identity}
            if originals != set(ALLOWED_RENAME) or mappings.get(ALLOWED_RENAME[0]) != ALLOWED_RENAME[1]:
                raise EvidenceError(f"Mapped identities collide: {target}")
            # Both exact heads contain this one explicitly reviewed replacement.
            # Preserve two baseline observations as one stronger current case.
            mapped[target].append(identity)
        else:
            mapped[target] = [identity]
        baseline_tests[identity] = {"target": target, "requirePass": "passed" in [pr99, pr49]}
    expected = set(discovery)
    if selection is not None:
        regex = re.compile(selection)
        expected = {identity for identity in expected if regex.search(identity)}
        if not expected:
            raise EvidenceError("Fixture selection discovered no tests")
    outcomes = run["outcomes"]
    if expected != set(outcomes):
        raise EvidenceError("Discovery/execution mismatch: missing=" + repr(sorted(expected - set(outcomes)))
                            + "; undiscovered=" + repr(sorted(set(outcomes) - expected)))
    failures = [identity for identity, value in outcomes.items() if value["outcome"] == "failed"]
    if failures:
        raise EvidenceError("Failed tests: " + ", ".join(failures))
    for identity in expected:
        module = outcomes[identity]["module"]
        if module is not None and module != discovery[identity]:
            raise EvidenceError(f"Discovery/execution module collision: {identity}")
    missing, downgraded = [], []
    for identity, row in baseline_tests.items():
        target = row["target"]
        if selection is not None and not re.search(selection, target):
            continue
        if target not in expected:
            missing.append(identity)
        elif row["requirePass"] and outcomes[target]["outcome"] != "passed":
            downgraded.append(identity)
        if target != identity and identity in discovery:
            raise EvidenceError(f"Both original and mapped test are present: {identity}")
    if missing or downgraded:
        raise EvidenceError("Baseline regression: missing=" + repr(missing) + "; pass-to-nonpass=" + repr(downgraded))
    for identity in require_pass or []:
        normalized, _ = normalize(identity)
        if normalized not in outcomes or outcomes[normalized]["outcome"] != "passed":
            raise EvidenceError(f"Provisioned fixture test did not pass: {normalized}")
    source_report = None
    if source_baseline is not None:
        if source_baseline.get("schemaVersion") != 1 or source_baseline.get("sourceHeads") != HEADS or sources is None:
            raise EvidenceError("Invalid source inventory baseline")
        declarations = {identity for candidate in source_baseline["candidates"]
                        for file in candidate["files"] for identity in file["declaredTests"]}
        missing_declarations = sorted(identity for identity in declarations if mappings.get(identity, identity) not in sources)
        if missing_declarations:
            raise EvidenceError("Source test declarations disappeared: " + repr(missing_declarations))
        source_report = {"baselineUniqueDeclarations": len(declarations), "actualUniqueDeclarations": len(sources),
                         "retained": True}
    return {"status": "passed", "platform": baseline["platform"], "sourceHeads": HEADS,
            "scope": "fixture" if selection is not None else "full", "selection": selection,
            "discovered": len(expected), "completed": len(outcomes), "summary": run["summary"],
            "baselineIdentities": len(baseline_tests), "requiredBaselinePasses": sum(row["requirePass"] for row in baseline_tests.values()),
            "baselineExecutionTargets": len(mapped),
            "requiredPassTargets": len({row["target"] for row in baseline_tests.values() if row["requirePass"]}),
            "sourceAccounting": source_report,
            "outcomes": {identity: row["outcome"] for identity, row in sorted(outcomes.items())}}


def pinned_manifest(directory: Path, name: str) -> dict:
    path = directory / name
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if MANIFEST_HASHES.get(name) != digest:
        raise EvidenceError(f"Immutable baseline pin mismatch: {name}")
    return read_json(path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=["macos", "linux", "macos-arm64", "linux-x86_64", "linux-arm64"])
    parser.add_argument("--architecture", choices=["arm64", "aarch64", "x86_64"])
    parser.add_argument("--discovery", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline-directory", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--scope", choices=["full", "fixture"], default="full")
    parser.add_argument("--selection", help="Explicit class/identity regex used for a filtered fixture run")
    parser.add_argument("--require-pass", type=Path, help="JSON array of exact provisioned fixture identities")
    parser.add_argument("--source-head", help="Actual tested integration commit (40 hex digits)")
    parser.add_argument("--test-exit-code", type=int, help="Captured exit code of the actual Swift test process")
    args = parser.parse_args(argv)
    report = {"status": "failed", "requestedPlatform": args.platform,
              "sourceHeads": HEADS, "testedSourceHead": args.source_head}
    try:
        if args.scope == "fixture" and not args.selection or args.scope == "full" and args.selection:
            raise EvidenceError("Fixture runs require --selection; full runs forbid it")
        if args.scope == "fixture" and args.require_pass is None:
            raise EvidenceError("Fixture runs require an explicit --require-pass identity list")
        platform = args.platform
        architecture = args.architecture or host_platform.machine().lower()
        if platform == "macos":
            if architecture not in {"arm64", "aarch64"}:
                raise EvidenceError("The Mac baseline is native arm64")
            platform = "macos-arm64"
        elif platform == "linux":
            if architecture not in {"arm64", "aarch64", "x86_64"}:
                raise EvidenceError("The Linux baseline requires a known native architecture")
            platform = "linux-arm64" if architecture in {"arm64", "aarch64"} else "linux-x86_64"
        if args.architecture is not None:
            canonical = "arm64" if architecture in {"arm64", "aarch64"} else "x86_64"
            if not platform.endswith(canonical):
                raise EvidenceError("Conflicting platform/architecture arguments")
        if args.test_exit_code is not None and args.test_exit_code != 0:
            raise EvidenceError(f"Swift test process exited with {args.test_exit_code}")
        if args.source_head is not None and not re.fullmatch(r"[a-f0-9]{40}", args.source_head):
            raise EvidenceError("Invalid tested source head")
        repository = Path(__file__).resolve().parents[2]
        directory = args.baseline_directory or repository / "docs/reconciliation-baselines"
        baseline = pinned_manifest(directory, "baseline-" + platform + ".json")
        mappings = mapping_document(pinned_manifest(directory, "reviewed-test-mappings.json"), platform)
        source_baseline = pinned_manifest(directory, "source-test-baseline.json")
        discovery_text = args.discovery.read_text(encoding="utf-8")
        log_text = args.log.read_text(encoding="utf-8")
        required = read_json(args.require_pass) if args.require_pass else []
        if not isinstance(required, list) or any(not isinstance(value, str) for value in required) or len(set(required)) != len(required):
            raise EvidenceError("Malformed/duplicate fixture identity list")
        report = validate(baseline, parse_discovery(discovery_text), parse_log(log_text, args.scope), mappings,
                          source_baseline, source_inventory(args.source_root or repository / "Tests"),
                          required, args.selection)
        report["testedSourceHead"] = args.source_head
        report["testExitCode"] = args.test_exit_code
        report["discoverySHA256"] = hashlib.sha256(args.discovery.read_bytes()).hexdigest()
        report["logSHA256"] = hashlib.sha256(args.log.read_bytes()).hexdigest()
    except (EvidenceError, OSError, ValueError, KeyError, TypeError) as error:
        report["error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Reconciliation test gate: {report['status']}" + (": " + report["error"] if "error" in report else ""))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
