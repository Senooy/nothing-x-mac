cask "nothing-x" do
  version "0.3.1"
  sha256 "357fca4c8bd6a49f62812a81b9e81a5e2f4070775cab2a8c4d6714d898a8b12d"

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
