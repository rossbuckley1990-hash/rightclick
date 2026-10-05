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
  https://github.com/ross-buckley/rightclick/releases/download/v0.1.0/rightclick-0.1.0-arm64.tar.gz) ;;
  *)
    echo "Refusing URL that is not a ross-buckley/rightclick GitHub Release asset." >&2
    exit 1
    ;;
esac
if [ ! -f "${ARCHIVE}" ]; then
  echo "Archive not found: ${ARCHIVE}" >&2
  exit 1
fi
scripts/validate-release.sh dist/RIGHTCLICK.app
REMOTE=$(mktemp -d)
trap 'rm -rf "$REMOTE"' EXIT HUP INT TERM
curl --fail --location --proto '=https' --tlsv1.2 "$URL" -o "$REMOTE/asset.tar.gz"
cmp "$ARCHIVE" "$REMOTE/asset.tar.gz"
tar -xzf "$REMOTE/asset.tar.gz" -C "$REMOTE"
scripts/validate-release.sh "$REMOTE/RIGHTCLICK.app"
SHA=$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')
FORMULA="packaging/homebrew/rightclick.rb"
cat > "${FORMULA}" << EOF
class Rightclick < Formula
  desc "Install an app. Your AI learns what it can do."
  homepage "https://github.com/ross-buckley/rightclick"
  url "${URL}"
  sha256 "${SHA}"
  version "0.1.0"
  license "Apache-2.0"

  depends_on :macos => :sonoma
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
cp "$FORMULA" packaging/tap/Formula/rightclick.rb
echo "Wrote ${FORMULA}"
echo "sha256 ${SHA}"
