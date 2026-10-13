cask "nothing-x" do
  version "0.2.1"
  sha256 "ff7a89eac6078188e21f3cd6a160fe97427c72b8d5e3d3006c92eb214636b8ce"

  url "https://github.com/Senooy/nothing-x-mac/releases/download/v#{version}/NothingX-#{version}.dmg"
  name "Nothing X"
  desc "Unofficial controller for the Nothing Headphone (1)"
  homepage "https://github.com/Senooy/nothing-x-mac"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Nothing X.app"

  zap trash: [
    "~/Library/Caches/dev.younes.NothingX",
    "~/Library/HTTPStorages/dev.younes.NothingX",
    "~/Library/Preferences/dev.younes.NothingX.plist",
    "~/Library/Saved Application State/dev.younes.NothingX.savedState",
  ]

  caveats "Requires macOS 14.2 or later."
end
