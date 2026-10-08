#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-kafka.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/Sources/RightClickCore" "$WORK/Tests/RightClickCoreTests"
cp "$ROOT"/Sources/RightClickCore/*.swift "$WORK/Sources/RightClickCore/"
cp "$ROOT/Tests/RightClickCoreTests/KafkaCapabilityTests.swift" "$WORK/Tests/RightClickCoreTests/"
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RightClickKafkaValidation", platforms: [.macOS(.v14)], targets: [
    .target(name: "RightClickCore", swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit")]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"], swiftSettings: [.swiftLanguageMode(.v5)])
])
PACKAGE
(cd "$WORK" && swift test --jobs 2)
