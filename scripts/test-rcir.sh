#!/usr/bin/env bash
# Exact-source focused RCIR gate. This is NOT full runtime acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v swift >/dev/null || { echo 'A Swift 6 toolchain is required.' >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-rcir.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
swift --version
printf '\nScope: six exact RCIR test classes through the actual package graph.\n'
printf 'The focused gate includes the real execution-host synchronization case; it is separate from complete product and live-provider acceptance.\n'
FILTER='^RightClickCoreTests\.(RCIRTests|RCIRBoundaryTests|RCIRIntegrationTests|RCIRInvocationIsolationTests|RCIRUnitCompletionTests|RCIRAuthorityTests)/'
(cd "$ROOT" && swift test --force-resolved-versions --scratch-path "$WORK" --jobs 4 --filter "$FILTER")
