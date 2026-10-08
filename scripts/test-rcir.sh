#!/usr/bin/env bash
# Exact-source Foundation-only gate. This is NOT full runtime acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v swift >/dev/null || { echo 'A Swift 6 toolchain is required.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-rcir.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/Sources/RightClickCore" "$WORK/Tests/RightClickCoreTests"
for name in CapabilityABI RCIR RCIRSignedReceipt RCIRAuthority; do
    cp "$ROOT/Sources/RightClickProtocol/$name.swift" "$WORK/Sources/RightClickCore/"
done
for name in RCIRTests RCIRBoundaryTests RCIRIntegrationTests RCIRInvocationIsolationTests RCIRUnitCompletionTests RCIRAuthorityTests; do
    sed '/@testable import RightClickProtocol/d; /@testable import RightClickProviders/d; /@testable import RightClickMacOS/d' "$ROOT/Tests/RightClickCoreTests/$name.swift" > "$WORK/Tests/RightClickCoreTests/$name.swift"
done
cat > "$WORK/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "RightClickRCIRValidation", platforms: [.macOS(.v14)],
dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0")], targets: [
    .target(name: "RightClickCore", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "RightClickCoreTests", dependencies: ["RightClickCore"],
                swiftSettings: [.swiftLanguageMode(.v5)])
])
PACKAGE
swift --version
printf '\nScope: exact ABI + RCIR foundation. No live providers or production engine.\n'
printf 'Frozen foundation plus authority, unit completion and invocation isolation. This is separate from the complete product gate.\n'
(cd "$WORK" && swift test)
