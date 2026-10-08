#!/usr/bin/env bash
# A separate-process local fixture, NOT the eleven-substrate/seven-operation demo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
command -v swiftc >/dev/null
command -v openssl >/dev/null
"$PYTHON" -c 'import cryptography'
if [[ $# -ne 1 || -e "$1" ]]; then
    echo 'Supply one NEW evidence output directory; existing evidence is never overwritten.' >&2
    exit 2
fi
mkdir -p -- "$1"
OUTPUT="$(cd "$1" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rightclick-receipt.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
swiftc -swift-version 5 \
    "$ROOT/Sources/RightClickCore/CapabilityABI.swift" \
    "$ROOT/Sources/RightClickCore/RCIR.swift" \
    "$ROOT/Sources/RightClickCore/RCIRAuthority.swift" \
    "$ROOT/Sources/RightClickCore/RCIRSignedReceipt.swift" \
    "$ROOT/examples/rcir-receipt-fixture/main.swift" -o "$WORK/receipt-fixture"
PYTHON_BIN="$(command -v "$PYTHON")"
"$WORK/receipt-fixture" "$PYTHON_BIN" "$ROOT/examples/rcir-receipt-fixture/producer.py" \
    "$WORK/good.txt" "$OUTPUT/success-payload.bin" 'RCIR external result verified' > "$OUTPUT/external-success.json"
"$WORK/receipt-fixture" "$PYTHON_BIN" "$ROOT/examples/rcir-receipt-fixture/producer.py" \
    "$WORK/bad.txt" "$OUTPUT/mismatch-payload.bin" 'Not the required external result' > "$OUTPUT/external-mismatch.json"
"$PYTHON" "$ROOT/examples/rcir-receipt-fixture/sign-and-check.py" "$OUTPUT"
