#!/usr/bin/env python3
"""Compile unchanged helper sources and XCTest cases in a dependency-free slice.

This tests actual selection/preflight/assessment code plus the original
Capability records. It does NOT execute the macOS runtime, MCP, provider
transports, Keychain, or the native engine integration tests.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCES = ["CapabilitySelection.swift", "CapabilityArgumentPreflight.swift", "CapabilityEffectAssessment.swift"]
TESTS = ["SemanticPreflightFixtures.swift", "CapabilitySelectionTests.swift", "CapabilityArgumentPreflightTests.swift", "CapabilityEffectAssessmentTests.swift"]

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--model-root", type=Path, help="Optional source root for original Capability.swift")
    parser.add_argument("--engine-root", type=Path, help="Also exercise the engine admission paths with explicit OS/transport test doubles from this source root")
    args = parser.parse_args()
    root = args.root.resolve()
    models_root = (args.model_root or root).resolve()
    swift = shutil.which("swift")
    if not swift:
        parser.error("Swift 6+ is required; no tests were run.")
    original = (models_root / "Sources/RightClickCore/Capability.swift").read_text()
    prefix, separator, _ = original.partition("public enum CapabilityID {")
    if not separator or "public struct Capability:" not in prefix:
        parser.error("Original Capability model boundary not found; refusing guessed source.")
    # CryptoKit is used only below the selected records, in CapabilityID.
    models = prefix.replace("import CryptoKit\n", "")
    if args.engine_root:
        # Select the matching source version's real models, store and deduper.
        original = (args.engine_root.resolve() / "Sources/RightClickCore/Capability.swift").read_text()
        head, separator, _ = original.partition("public enum CapabilityID {")
        tail_marker = "public enum RunStatus:"
        if not separator or tail_marker not in original:
            parser.error("Original model/identity boundary unavailable")
        models = head.replace("import CryptoKit\n", "") + original[original.index(tail_marker):]

    with tempfile.TemporaryDirectory(prefix="rightclick-preflight-tests-") as tmp:
        work = Path(tmp)
        source_dir = work / "Sources/RightClickCore"
        test_dir = work / "Tests/RightClickCoreTests"
        source_dir.mkdir(parents=True); test_dir.mkdir(parents=True)
        (work / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PreflightAcceptance", targets: [
    .target(name: "RightClickCore"),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"])
])
''')
        (source_dir / "CapabilityRecords.swift").write_text(models)
        for name in SOURCES:
            shutil.copyfile(root / "Sources/RightClickCore" / name, source_dir / name)
        tests = list(TESTS)
        if args.engine_root:
            engine = (args.engine_root.resolve() / "Sources/RightClickCore/CapabilityEngine.swift").read_text()
            engine = engine.replace("import AppKit\n", "").replace("import Darwin\n", "")
            (source_dir / "CapabilityEngine.swift").write_text(engine)
            shutil.copyfile(root / "scripts/fixtures/semantic-preflight-engine-stubs.swift", source_dir / "TestDoubles.swift")
            tests.append("ExecutionPreflightIntegrationTests.swift")
        for name in tests:
            shutil.copyfile(root / "Tests/RightClickCoreTests" / name, test_dir / name)
        subprocess.run([swift, "--version"], check=True)
        result = subprocess.run([swift, "test", "--package-path", str(work), "--jobs", "2"], timeout=180)
        print("VALIDATION_BOUNDARY=" + ("source_engine_admission_with_explicit_test_doubles" if args.engine_root else "portable_helpers_and_original_model_records"))
        print("MACOS_ENGINE_AND_MCP_TESTED=NO")
        return result.returncode

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"Acceptance failed: {exc}") from exc
