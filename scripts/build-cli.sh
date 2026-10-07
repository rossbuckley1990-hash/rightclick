#!/bin/sh
# Build the shared runtime. Native link options apply only on their host.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
METADATA="$ROOT/Sources/RightClickCore/BuildMetadata.generated.swift"
python3 scripts/build-provenance.py --output "$METADATA"
trap 'rm -f "$METADATA"' EXIT HUP INT TERM
set --
case "$(uname -s)" in
  Darwin) set -- -Xlinker -oso_prefix -Xlinker "$ROOT/" ;;
esac
ZERO_AR_DATE=1 swift build -c release --product rightclick --force-resolved-versions \
  -Xswiftc -DRIGHTCLICK_BUILD_METADATA \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xcc "-fdebug-prefix-map=$ROOT=/rightclick" \
  -Xcc "-ffile-prefix-map=$ROOT=/rightclick" \
  "$@"
.build/release/rightclick version
echo "Built .build/release/rightclick"
