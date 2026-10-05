#!/bin/sh
# Archive an already staged bundle. Never rebuild a signed artifact.
set -eu
cd "$(dirname "$0")/.."
MODE="${1:-}"
APP="dist/RIGHTCLICK.app"
ARCHIVE="dist/rightclick-0.1.0-arm64.tar.gz"
if [ "$MODE" = "--development" ]; then
  ARCHIVE="dist/rightclick-0.1.0-arm64-development.tar.gz"
elif [ -n "$MODE" ]; then
  echo "Usage: scripts/make-release-archive.sh [--development]" >&2
  exit 2
else
  scripts/validate-release.sh "$APP"
fi
test -f "$APP/Contents/MacOS/rightclick"
python3 scripts/deterministic-archive.py "$APP" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
echo "Archive: $(pwd)/$ARCHIVE"
