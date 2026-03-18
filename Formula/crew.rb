# Homebrew formula for crew
# Install: brew tap garnetlyx/crew && brew install crew
# Or: brew install garnetlyx/crew/crew

class Crew < Formula
  desc "Multi-agent orchestration tool for AI-assisted development"
  homepage "https://github.com/garnetlyx/crew"
  version "0.4.0"
  url "https://github.com/garnetlyx/crew/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "6ed570afb60e7a2351fc5608a21a77265c098fd2df0ec6e457b615e7982cb3e3"
  license "MIT"

  depends_on "bash"
  depends_on "yq"

  def install
    libexec.install "crew.sh", "design.sh", "install.sh", "uninstall.sh"
    libexec.install "lib"
    libexec.install "plugins"
    libexec.install "prompts"
    libexec.install "templates"

    (bin/"crew").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/crew.sh" "$@"
    EOS

    (bin/"design").write <<~EOS
      #!/bin/bash
      exec "#{libexec}/design.sh" "$@"
    EOS
  end

  test do
    assert_match "crew", shell_output("#{bin}/crew --version")
    assert_match "design", shell_output("#{bin}/design --help")
  end
end
