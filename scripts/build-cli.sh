#!/bin/sh
# Primary v0.1 CLI build. No paid Apple account or app bundle is needed.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd -P)
ZERO_AR_DATE=1 swift build -c release --product rightclick --force-resolved-versions \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xcc "-fdebug-prefix-map=$ROOT=/rightclick" \
  -Xcc "-ffile-prefix-map=$ROOT=/rightclick" \
  -Xlinker -oso_prefix -Xlinker "$ROOT/"
.build/release/rightclick version
echo "Built .build/release/rightclick"
