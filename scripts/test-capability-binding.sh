#!/usr/bin/env bash
# Foundation-only ABI + invocation binding tests, not full runtime acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v swift >/dev/null || { echo 'Swift 6.2+ is required.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-binding.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/Sources/RightClickCore" "$WORK/Tests/RightClickCoreTests"
for name in CapabilityABI CapabilityInvocationBinding; do
    cp "$ROOT/Sources/RightClickCore/$name.swift" "$WORK/Sources/RightClickCore/"
done
for name in CapabilityABITests CapabilityABIBoundaryTests CapabilityInvocationBindingTests; do
    cp "$ROOT/Tests/RightClickCoreTests/$name.swift" "$WORK/Tests/RightClickCoreTests/"
done
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RightClickBindingValidation", targets: [
    .target(name: "RightClickCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"],
                swiftSettings: [.swiftLanguageMode(.v5)])
])
PACKAGE
swift --version
printf '\nScope: exact ABI and binding sources; 51 portable tests; no native engine.\n'
(cd "$WORK" && swift test)
