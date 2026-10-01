#!/bin/zsh
# Signs with your developer team and installs straight onto a connected iPad.
# First time: plug the iPad in by USB, unlock it, tap Trust, and turn on
# Settings > Privacy & Security > Developer Mode. After that Wi-Fi works too.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
ipad=$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ && (/available/ || /connected/) {for(i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) print $i}' | head -1)
if [[ -z "$ipad" ]]; then
  echo "No iPad found. Connected devices:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Installing on $ipad"
# -allowProvisioningUpdates registers the iPad with your team and makes the profile.
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMac -configuration Release \
  -destination "platform=iOS,id=$ipad" -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD"
xcrun devicectl device install app --device "$ipad" build/Build/Products/Release-iphoneos/RemoteMac.app
xcrun devicectl device process launch --device "$ipad" com.bgrayson.remotemac.ipad || true
