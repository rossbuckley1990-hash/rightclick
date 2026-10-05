#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APP="dist/RIGHTCLICK.app"
if [ -d "$APP" ]; then
  echo "Refusing to replace an existing release bundle. Move dist/RIGHTCLICK.app aside first." >&2
  exit 1
fi
ROOT=$(pwd -P)
# Normalize compiler-recorded source paths; keep dependency revisions pinned.
ZERO_AR_DATE=1 swift build -c release --product rightclick --force-resolved-versions \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/rightclick" \
  -Xcc "-fdebug-prefix-map=$ROOT=/rightclick" \
  -Xcc "-ffile-prefix-map=$ROOT=/rightclick" \
  -Xlinker -oso_prefix -Xlinker "$ROOT/"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/rightclick "$APP/Contents/MacOS/rightclick"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R packaging/ThirdPartyLicenses "$APP/Contents/Resources/ThirdPartyLicenses"
chmod 755 "$APP/Contents/MacOS/rightclick"
echo "Binary: $(pwd)/.build/release/rightclick"
echo "Staged bundle: $(pwd)/$APP (development artifact)"
