#!/bin/sh
# Write the deferred Homebrew URL and sha256 after a real release asset exists.
# Refuses to invent a URL.
set -eu
cd "$(dirname "$0")/.."
URL="${1:-}"
ARCHIVE="${2:-dist/rightclick-0.1.0-arm64.tar.gz}"
if [ -z "${URL}" ]; then
  echo "DEFERRED: pass the published asset URL as the first argument." >&2
  echo "Example: scripts/fill-homebrew-formula.sh https://github.com/ross-buckley/rightclick/releases/download/v0.1.0/rightclick-0.1.0-arm64.tar.gz" >&2
  exit 1
fi
case "${URL}" in
  https://github.com/ross-buckley/rightclick/releases/download/*) ;;
  *)
    echo "Refusing URL that is not a ross-buckley/rightclick GitHub Release asset." >&2
    exit 1
    ;;
esac
if [ ! -f "${ARCHIVE}" ]; then
  echo "Archive not found: ${ARCHIVE}" >&2
  exit 1
fi
SHA=$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')
FORMULA="packaging/homebrew/rightclick.rb"
cat > "${FORMULA}" << EOF
class Rightclick < Formula
  desc "Install an app. Your AI learns what it can do."
  homepage "https://github.com/ross-buckley/rightclick"
  url "${URL}"
  sha256 "${SHA}"
  version "0.1.0"

  depends_on :macos => :sonoma
  depends_on arch: :arm64

  def install
    bin.install "rightclick"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/rightclick version")
  end
end
EOF
echo "Wrote ${FORMULA}"
echo "sha256 ${SHA}"
