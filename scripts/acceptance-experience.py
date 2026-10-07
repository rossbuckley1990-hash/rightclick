#!/usr/bin/env python3
"""Run the actual portable ledger and its XCTest suite, without macOS adapters.
This is a component gate, not evidence that the full runtime works on Linux.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="rightclick-experience-") as temp:
    package = Path(temp)
    for folder, filename in [
        ("Sources/RightClickCore", "CapabilityExperienceLedger.swift"),
        ("Tests/RightClickCoreTests", "CapabilityExperienceLedgerTests.swift"),
    ]:
        (package / folder).mkdir(parents=True)
        shutil.copy2(root / folder / filename, package / folder / filename)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RightClickExperienceGate", targets: [
    .target(name: "RightClickCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"],
                swiftSettings: [.swiftLanguageMode(.v5)])
])
''')
    subprocess.run(["swift", "test", "--package-path", str(package)], check=True, timeout=180)
