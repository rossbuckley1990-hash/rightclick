#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product rightclick
echo "Binary: $(pwd)/.build/release/rightclick"
