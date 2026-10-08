#!/usr/bin/env bash
# Test the actual package and native host backend; no reduced copy of the core.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(cd "$ROOT" && swift test --force-resolved-versions --jobs 2 --filter CapabilityInterfaceTests)
