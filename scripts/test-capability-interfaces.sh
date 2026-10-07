#!/usr/bin/env bash
# Exact production-source gate without a second Swift dependency checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-interfaces.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/Sources/RightClickCore" "$WORK/Tests/RightClickCoreTests"
cp "$ROOT"/Sources/RightClickCore/*.swift "$WORK/Sources/RightClickCore/"
cp "$ROOT/Tests/RightClickCoreTests/CapabilityInterfaceTests.swift" "$WORK/Tests/RightClickCoreTests/"
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RightClickInterfaceValidation", platforms: [.macOS(.v14)], targets: [
    .target(name: "RightClickCore", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit")]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"], swiftSettings: [.swiftLanguageMode(.v5)])
])
PACKAGE
(cd "$WORK" && swift test --jobs 2)
