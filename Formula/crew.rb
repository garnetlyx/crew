# Homebrew formula for crew
# Install: brew tap garnetlyx/crew && brew install crew
# Or: brew install garnetlyx/crew/crew

class Crew < Formula
  desc "Multi-agent orchestration tool for AI-assisted development"
  homepage "https://github.com/garnetlyx/crew"
  version File.read(File.expand_path("../../VERSION", __FILE__)).strip rescue "0.0.0"
  url "https://github.com/garnetlyx/crew/archive/refs/tags/v#{version}.tar.gz"
  # sha256 "UPDATE_WITH_ACTUAL_SHA256_AFTER_RELEASE"
  license "MIT"

  depends_on "bash" => "4.0"
  depends_on "yq"

  def install
    # Install all shell scripts preserving directory structure
    libexec.install "crew.sh", "design.sh", "install.sh", "uninstall.sh"
    libexec.install "lib"
    libexec.install "plugins"
    libexec.install "prompts"
    libexec.install "templates"

    # Create wrapper scripts that point to libexec
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
