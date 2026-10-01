#!/bin/zsh
# Builds the Mac host, installs it in /Applications and starts it.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMacHost -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build -allowProvisioningUpdates build | grep -E "error:|BUILD"
pkill -x RemoteMacHost || true
# Opening while the old one is still exiting fails with LaunchServices error -600.
for i in {1..50}; do pgrep -x RemoteMacHost >/dev/null || break; sleep 0.1; done
rm -rf "/Applications/Remote Mac Host.app"
cp -R build/Build/Products/Release/RemoteMacHost.app "/Applications/Remote Mac Host.app"
if launchctl print gui/$(id -u)/com.bgrayson.remotemac.keepalive >/dev/null 2>&1; then
  # launchd owns it (scripts/keepalive-host.sh): restart through launchd, not alongside it.
  launchctl kickstart -k gui/$(id -u)/com.bgrayson.remotemac.keepalive
else
  open "/Applications/Remote Mac Host.app"
fi
for i in {1..50}; do pgrep -x RemoteMacHost >/dev/null && break; sleep 0.1; done
if ! pgrep -x RemoteMacHost >/dev/null; then
  echo "Remote Mac Host did not start. Open /Applications/Remote Mac Host.app by hand." >&2
  exit 1
fi
echo "Running. Click the display icon in the menu bar for the pairing code and permissions."
