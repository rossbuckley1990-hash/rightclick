#!/usr/bin/env bash
# Test execution retention in the actual package with its native host backend.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
(cd "$ROOT" && swift test --force-resolved-versions --jobs 2 --filter ExecutionRetentionTests)
