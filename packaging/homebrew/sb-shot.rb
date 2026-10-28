# Template for the cask in Osmait/homebrew-tap. The release workflow fills in
# the version and checksum and pushes it to the tap.
cask "sb-shot" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/Osmait/sb-shot/releases/download/v#{version}/SbShot-#{version}.dmg"
  name "sb-shot"
  desc "Menu bar app for screenshots, screen recordings and annotations"
  homepage "https://github.com/Osmait/sb-shot"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "SbShot.app"

  uninstall quit: "com.burgos.sb-shot"

  zap trash: [
    "~/Library/Application Scripts/com.burgos.sb-shot",
    "~/Library/Containers/com.burgos.sb-shot",
  ]
end
