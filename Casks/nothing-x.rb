cask "nothing-x" do
  version "0.4.0"
  sha256 "8fe8646a1d5bd1a8b5a345b2120771f7f6b48adcd95dace739c864dbe79aff84"

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
