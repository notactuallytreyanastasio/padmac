#!/bin/zsh
# Builds the Mac host, installs it in /Applications and starts it.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
build() {
  xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMacHost -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build "$@" build > build/host.log 2>&1
}
mkdir -p build
# project.yml signs with the author's developer team. Anyone else's Xcode can't
# sign as that team, so fall back to a local (ad-hoc) signature, which is all a
# Mac needs to run an app built on it. The catch: macOS ties Screen Recording
# and Accessibility to the signature, and an ad-hoc one changes on every build,
# so after rebuilding you grant both again.
if build -allowProvisioningUpdates; then
  grep -E "BUILD" build/host.log
else
  echo "Couldn't sign with the project's developer team; signing locally instead."
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= || { grep -E "error:" build/host.log; echo "Build failed. Full log: build/host.log" >&2; exit 1; }
  grep -E "BUILD" build/host.log
fi
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
