#!/bin/sh
# Local rehearsal only; never produces the public-release filename.
set -eu
cd "$(dirname "$0")/.."
scripts/make-release-archive.sh --development
SHA=$(shasum -a 256 dist/rightclick-0.1.0-arm64-development.tar.gz | awk '{print $1}')
ARCHIVE="$(pwd)/dist/rightclick-0.1.0-arm64-development.tar.gz"
cat > dist/rightclick.rb << EOF
class Rightclick < Formula
  desc "Install an app. Your AI learns what it can do."
  homepage "https://github.com/ross-buckley/rightclick"
  version "0.1.0"
  license "Apache-2.0"
  url "file://${ARCHIVE}"
  sha256 "${SHA}"
  depends_on macos: :sonoma
  depends_on arch: :arm64

  def install
    (libexec/"RIGHTCLICK.app").install "Contents"
    bin.install_symlink libexec/"RIGHTCLICK.app/Contents/MacOS/rightclick"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/rightclick version")
  end
end
EOF
echo "Local formula: $(pwd)/dist/rightclick.rb (development only)"
