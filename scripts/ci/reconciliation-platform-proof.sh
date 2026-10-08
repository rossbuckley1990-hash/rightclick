#!/usr/bin/env bash
# Independent target builds, complete suite, retention gate and local MCP proof.
set -euo pipefail
platform="$1"
architecture="$2"
evidence="$3"
mkdir -p "$evidence"
export RIGHTCLICK_SUBSTRATE_EVIDENCE="$evidence/substrate-registered.json"
python3 -m unittest discover -s scripts/ci/tests -v 2>&1 | tee "$evidence/ci-helper-tests.log"
python3 -m unittest discover -s Tests/ci -v 2>&1 | tee "$evidence/identity-gate-tests.log"
python3 scripts/ci/record-reconciliation-source.py "$evidence/source.json" --expected-arch "$architecture"
task_build="$RUNNER_TEMP/rightclick-primary-build"
targets=(RightClickProtocol RightClickProviders RightClickCore RightClickMCP RightClickLink RightClickHostFiles RightClickARD)
case "$platform" in
  macos) targets+=(RightClickMacOSHost RightClickMacOS);;
  linux) targets+=(RightClickLinux);;
  *) exit 2;;
esac
for target in "${targets[@]}"; do
  swift build --scratch-path "$task_build" --target "$target" --force-resolved-versions --jobs 4 2>&1 | tee "$evidence/build-$target.log"
done
set +e
swift test --scratch-path "$task_build" --force-resolved-versions --jobs 4 2>&1 | tee "$evidence/full-tests.log"
test_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$test_status" > "$evidence/full-tests.exit"
swift test --scratch-path "$task_build" list --skip-build > "$evidence/discovery.txt" 2> "$evidence/discovery.stderr"
set +e
python3 scripts/ci/check-reconciliation-tests.py --platform "$platform" --architecture "$architecture" \
  --source-head "$(git -c safe.directory="$GITHUB_WORKSPACE" rev-parse HEAD)" \
  --test-exit-code "$test_status" --discovery "$evidence/discovery.txt" \
  --log "$evidence/full-tests.log" --output "$evidence/test-identity-outcomes.json"
gate_status=$?
set -e
python3 - "$evidence" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
warnings = sorted({line.strip() for path in root.glob('*.log') for line in path.read_text(errors='replace').splitlines() if 'warning:' in line})
(root / 'compiler-warnings.json').write_text(json.dumps({'uniqueWarningCount': len(warnings), 'warnings': warnings}, indent=2) + '\n')
PY
if (( test_status != 0 )); then exit "$test_status"; fi
if (( gate_status != 0 )); then exit "$gate_status"; fi
if [[ "$platform" == macos ]]; then
  RIGHTCLICK_LIVE_UNICODE_SERVICE=1 RIGHTCLICK_TEST_SCRATCH_PATH="$task_build" \
    bash scripts/ci/run-fixture-tests.sh NativeServiceUnicodeLiveAcceptanceTests \
      "$evidence/native-services.log" "$evidence/native-services-outcomes.json" \
      --require-class NativeServiceUnicodeLiveAcceptanceTests
fi
swift build --scratch-path "$task_build" -c release --product rightclick --force-resolved-versions --jobs 4 2>&1 | tee "$evidence/release-build.log"
binary_directory="$(swift build --scratch-path "$task_build" -c release --show-bin-path)"
"$binary_directory/rightclick" version > "$evidence/cli-version.txt"
python3 - "$binary_directory/rightclick" "$evidence/binary.json" <<'PY'
import hashlib, json, pathlib, sys
binary = pathlib.Path(sys.argv[1])
pathlib.Path(sys.argv[2]).write_text(json.dumps({'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest()}, indent=2) + '\n')
PY
python3 scripts/acceptance-portable-fabric.py "$binary_directory/rightclick" 2>&1 | tee "$evidence/portable-fabric-acceptance.log"
git -c safe.directory="$GITHUB_WORKSPACE" diff --exit-code
