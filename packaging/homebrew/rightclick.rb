class Rightclick < Formula
  desc "Install an app. Your AI learns what it can do"
  homepage "https://github.com/rossbuckley1990-hash/rightclick"
  url "https://github.com/rossbuckley1990-hash/rightclick/releases/download/v0.2.3/rightclick-0.2.3-source.tar.gz"
  sha256 "997febe6c50fe1e42722e4d76908af53c0364af507dc64d87396b845ede31851"
  license "Apache-2.0"

  # RIGHTCLICK owns this compatibility pin.
  # ChatGPT's modern tunnel path requires OpenAI tunnel-client >= 0.0.15.
  resource "openai-tunnel-client" do
    url "https://github.com/openai/tunnel-client/releases/download/v0.0.15/tunnel-client-v0.0.15-darwin-arm64.zip"
    sha256 "b2cae3aa9df45b4c2fe9b1d700ebacce39f9feb6a6b46b86e6499f9a51bf72ff"
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma
  uses_from_macos "swift" => :build, since: :sonoma

  def select_free_command_line_tools
    developer = Pathname("/Library/Developer/CommandLineTools")
    return unless (developer/"usr/bin/swift").exist?

    ENV["DEVELOPER_DIR"] = developer.to_s
    ENV["SDKROOT"] = (developer/"SDKs/MacOSX.sdk").to_s
    ENV.prepend_path "PATH", developer/"usr/bin"
    ENV["CC"] = (developer/"usr/bin/clang").to_s
    ENV["CXX"] = (developer/"usr/bin/clang++").to_s
  end

  def fetch
    select_free_command_line_tools
    compiler = Utils.safe_popen_read("swift", "--version")[/Swift version ([0-9.]+)/, 1]
    if !compiler || Version.new(compiler) < Version.new("6.2")
      odie "Source builds require Swift 6.2+ from the free Apple Command Line Tools."
    end
    # SwiftPM's manifest sandbox cannot nest inside Homebrew's build sandbox.
    # Homebrew still confines the build; its fetch phase permits dependencies.
    system "swift", "package", "--disable-sandbox", "--force-resolved-versions", "resolve"
  end

  def install
    select_free_command_line_tools
    ENV["ZERO_AR_DATE"] = "1"
    system "swift", "build", "--product", "rightclick", *std_swift_args,
           "--disable-sandbox", "--force-resolved-versions", "--skip-update",
           "-Xswiftc", "-debug-prefix-map", "-Xswiftc", "#{buildpath}=/rightclick",
           "-Xswiftc", "-file-prefix-map", "-Xswiftc", "#{buildpath}=/rightclick",
           "-Xcc", "-fdebug-prefix-map=#{buildpath}=/rightclick",
           "-Xcc", "-ffile-prefix-map=#{buildpath}=/rightclick",
           "-Xlinker", "-oso_prefix", "-Xlinker", "#{buildpath}/"
    bin.install ".build/release/rightclick"
    (pkgshare/"ThirdPartyLicenses").install Dir["packaging/ThirdPartyLicenses/*"]

    resource("openai-tunnel-client").stage do
      libexec.install(
        "tunnel-client",
        "cloudflared",
        "cloudflared-manifest.json"
      )

      tunnel_share = pkgshare/"OpenAITunnelClient"

      tunnel_share.install(
        "LICENSE",
        "NOTICE",
        "tunnel-client-v0.0.15-darwin-arm64-licenses.txt",
        "tunnel-client-v0.0.15-darwin-arm64.spdx.json"
      )
    end
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/rightclick version").strip
    text = JSON.parse(shell_output("#{bin}/rightclick inspect 'RightClick' --json"))
    assert_equal "text", text.fetch("kind")
    assert_equal "RightClick", text.fetch("text")
    assert_equal "public.plain-text", text.fetch("typeIdentifier")
    assert_equal 10, text.fetch("byteCount")

    assert_predicate libexec/"tunnel-client", :executable?

    assert_match(
      "0.0.15",
      shell_output("#{libexec}/tunnel-client --version")
    )
  end
end
