#!/usr/bin/env bash
# Actual portable package gate, separate from live broker acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift test --force-resolved-versions --filter 'KafkaCapabilityTests|KafkaAcquisitionStabilityTests'
