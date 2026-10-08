#!/bin/sh
# Build the shared runtime. Native link options apply only on their host.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
set --
case "$(uname -s)" in
  Darwin) set -- -Xlinker -oso_prefix -Xlinker "$ROOT/" ;;
esac
ZERO_AR_DATE=1 swift build -c release --product rightclick --force-resolved-versions \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xcc "-fdebug-prefix-map=$ROOT=/rightclick" \
  -Xcc "-ffile-prefix-map=$ROOT=/rightclick" \
  "$@"
.build/release/rightclick version
echo "Built .build/release/rightclick"
