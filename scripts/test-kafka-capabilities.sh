#!/usr/bin/env bash
# Real shared runtime gate; actual broker fixtures must be supplied by the host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift test --force-resolved-versions --jobs 4 \
  --filter 'KafkaCapabilityTests|KafkaAcquisitionStabilityTests'
