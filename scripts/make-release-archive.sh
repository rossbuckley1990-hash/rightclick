#!/bin/sh
# Build the arm64 release binary and a deterministic archive.
# Does not upload, sign, or notarise.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swift build -c release --product rightclick
# Copy out of the build tree so the archive member name is stable.
rm -rf dist/payload
mkdir -p dist/payload
cp .build/release/rightclick dist/payload/rightclick
# Touch a fixed mtime so the archive bytes do not depend on the build clock.
touch -t 202601010000 dist/payload/rightclick
tar --format ustar -C dist/payload -cf - rightclick | gzip -n > dist/rightclick-0.1.0-arm64.tar.gz
shasum -a 256 dist/rightclick-0.1.0-arm64.tar.gz
file dist/payload/rightclick
echo "Archive: $(pwd)/dist/rightclick-0.1.0-arm64.tar.gz"
echo "URL: DEFERRED until the GitHub Release asset exists"
