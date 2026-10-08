#!/usr/bin/env bash
# The selected XCTest command and the required actual fixture outcome gate.
set -euo pipefail
filter="$1"
log="$2"
outcomes="$3"
shift 3
mkdir -p "$(dirname "$log")"
build_options=(--force-resolved-versions --jobs 4)
if [[ -n "${RIGHTCLICK_TEST_SCRATCH_PATH:-}" ]]; then
  build_options+=(--scratch-path "$RIGHTCLICK_TEST_SCRATCH_PATH")
fi
set +e
swift test "${build_options[@]}" --filter "$filter" 2>&1 | tee "$log"
test_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$test_status" > "$log.exit"
set +e
python3 scripts/ci/check-fixture-test-outcomes.py --log "$log" --output "$outcomes" "$@"
gate_status=$?
set -e
if (( test_status != 0 )); then exit "$test_status"; fi
exit "$gate_status"
