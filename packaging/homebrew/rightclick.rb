# Unpublished Homebrew formula template.
# Do not brew tap or brew install this until a release URL exists.
class Rightclick < Formula
  desc "Give your AI the capabilities already installed on your Mac"
  # No public project URL yet. This template is not installable.
  homepage "https://example.invalid/rightclick"
  version "0.1.0"
  # No release archive exists. Do not publish or install from this template.
  url "https://example.invalid/rightclick-0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  depends_on :macos => :sonoma

  def install
    system "swift", "build", "-c", "release", "--product", "rightclick", "--disable-sandbox"
    bin.install ".build/release/rightclick"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/rightclick version")
  end
end
