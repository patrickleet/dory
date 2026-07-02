# Homebrew Cask for Dory. version + sha256 are bumped automatically by the release workflow, which
# also syncs this file to the Augani/homebrew-dory tap.  Install:  brew install --cask Augani/dory/dory
cask "dory" do
  version "0.2.0"
  sha256 "31ad465a38bbc10eed41e556a86d85d899b61ece0f67dc60a7b0df3a2aa98660"

  url "https://github.com/Augani/dory/releases/download/v#{version}/Dory-#{version}.zip"
  name "Dory"
  desc "Lightweight native macOS app for Docker and Linux containers on Apple silicon"
  homepage "https://github.com/Augani/dory"

  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Dory.app"

  zap trash: [
    "~/.dory",
    "~/Library/Application Support/com.pythonxi.Dory",
    "~/Library/Preferences/com.pythonxi.Dory.plist",
  ]
end
