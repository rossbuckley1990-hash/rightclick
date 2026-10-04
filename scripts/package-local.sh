#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product rightclick
mkdir -p dist
tar -C .build/release -czf dist/rightclick-0.1.0-arm64.tar.gz rightclick
SHA=$(shasum -a 256 dist/rightclick-0.1.0-arm64.tar.gz | awk '{print $1}')
ARCHIVE="$(pwd)/dist/rightclick-0.1.0-arm64.tar.gz"
cat > dist/rightclick.rb << EOF
class Rightclick < Formula
  desc "Give your AI the capabilities already installed on your Mac"
  homepage "https://github.com/ross-buckley/rightclick"
  version "0.1.0"
  license "MIT"
  url "file://${ARCHIVE}"
  sha256 "${SHA}"

  def install
    bin.install "rightclick"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/rightclick version")
  end
end
EOF
echo "archive ${ARCHIVE}"
echo "sha256 ${SHA}"
echo "formula $(pwd)/dist/rightclick.rb"
echo "Homebrew 7 rejects brew install of a formula outside a tap."
echo "Copy dist/rightclick.rb into a local tap Formula directory, then brew install <tap>/rightclick."
