class Simslim < Formula
  desc "Reduce iOS Simulator background-service overhead"
  homepage "https://github.com/janodev/swift-simslim"
  url "ssh://git@github.com/janodev/swift-simslim.git",
      revision: "b823b939c1b48f0a1a178fead12ebfd17f00536b"
  version "0.1.0"
  license "MIT"

  depends_on xcode: ["27.0", :build]
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  def install
    system "swift", "build",
           "--configuration", "release",
           "--disable-sandbox",
           "--product", "simslim"
    bin.install ".build/release/simslim"
  end

  def caveats
    <<~EOS
      simslim controls iOS simulators and needs full Xcode with an iOS
      Simulator runtime, not only the standalone Command Line Tools.
    EOS
  end

  test do
    assert_equal "simslim dev\n", shell_output("#{bin}/simslim --version")
  end
end
