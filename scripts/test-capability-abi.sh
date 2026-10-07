#!/usr/bin/env bash
# Run only the Foundation-only ABI tests. This is not full runtime acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v swift >/dev/null || { echo 'Swift 6.2+ is required.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-abi.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/Sources/RightClickCore" "$WORK/Tests/RightClickCoreTests"
cp "$ROOT/Sources/RightClickCore/CapabilityABI.swift" "$WORK/Sources/RightClickCore/"
for name in CapabilityABITests CapabilityABIBoundaryTests; do
    cp "$ROOT/Tests/RightClickCoreTests/$name.swift" "$WORK/Tests/RightClickCoreTests/"
done
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RightClickABIValidation", targets: [
    .target(name: "RightClickCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"],
                swiftSettings: [.swiftLanguageMode(.v5)])
])
PACKAGE
swift --version
printf '\nScope: exact ABI source + 33 portable tests; no AppKit/CryptoKit adapters.\n'
(cd "$WORK" && swift test)
