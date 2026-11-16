cask "bask" do
  version "2.19.1"
  sha256 "7d3ffd0efccf4db5faf063e8ecc03e897ee30d08e9fa3b007d127c63cbf187e2"

  url "https://github.com/edde746/bask/releases/download/#{version}/bask-macos.dmg"
  name "Bask"
  desc "Modern Plex and Jellyfin client built with Flutter"
  homepage "https://github.com/edde746/bask"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "Bask.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-cr", "{{appdir}}/Bask.app"],
        sudo: false
  end

  uninstall quit: "com.edde746.bask"

  zap trash: [
    "~/Library/Application Support/com.edde746.bask",
    "~/Library/Caches/com.edde746.bask",
    "~/Library/HTTPStorages/com.edde746.bask",
    "~/Library/Preferences/com.edde746.bask.plist",
    "~/Library/Saved Application State/com.edde746.bask.savedState",
    "~/Library/WebKit/com.edde746.bask",
  ]
end
