# Homebrew Cask for Dory. version + sha256 are bumped automatically by the release workflow, which
# also syncs this file to the Augani/homebrew-dory tap.  Install:  brew install --cask Augani/dory/dory
cask "dory" do
  version "0.2.0"
  sha256 "31ad465a38bbc10eed41e556a86d85d899b61ece0f67dc60a7b0df3a2aa98660"

  url "https://github.com/Augani/dory/releases/download/v#{version}/Dory-#{version}.zip"
  name "Dory"
  desc "Lightweight Docker and Linux container runtime"
  homepage "https://github.com/Augani/dory"

  # The cask intentionally follows the unsuffixed universal artifact. GitHub releases also publish
  # smaller arm64 and x86_64 downloads for users who want a platform-optimized app. Dory's built-in
  # shared-VM engine needs macOS 15 (Sequoia) or later; on macOS 14 Dory runs against any
  # Docker-compatible engine. The engine is bundled when release assets are available.
  depends_on macos: :sonoma

  app "Dory.app"

  zap trash: [
    "~/.dory",
    "~/Library/Application Support/com.pythonxi.Dory",
    "~/Library/Preferences/com.pythonxi.Dory.plist",
  ]
end
