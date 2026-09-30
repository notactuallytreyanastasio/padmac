#!/bin/zsh
# Builds the Mac host, installs it in /Applications and starts it.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMacHost -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD"
pkill -x RemoteMacHost || true
rm -rf "/Applications/Remote Mac Host.app"
cp -R build/Build/Products/Release/RemoteMacHost.app "/Applications/Remote Mac Host.app"
open "/Applications/Remote Mac Host.app"
echo "Running. Click the display icon in the menu bar for the pairing code and permissions."
