# Production formula for the planned tap ross-buckley/tap.
# Do not publish this file until the deferred fields below are real.
class Rightclick < Formula
  desc "Install an app. Your AI learns what it can do."
  homepage "https://github.com/ross-buckley/rightclick"
  version "0.1.0"
  # DEFERRED: GitHub Release asset URL for v0.1.0.
  # DEFERRED: sha256 of that exact asset.
  # scripts/fill-homebrew-formula.sh writes both after the release asset exists.
  # No URL is invented here.

  depends_on :macos => :sonoma
  depends_on arch: :arm64

  def install
    odie "Blocked: the v0.1.0 release asset URL and sha256 are not filled in yet."
    bin.install "rightclick"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/rightclick version")
  end
end
