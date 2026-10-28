#!/bin/zsh
# Signs with your developer team and installs Remote Mac Duo straight onto a
# connected iPhone Duo. First time: plug it in by USB, unlock it, tap Trust,
# and turn on Settings > Privacy & Security > Developer Mode. After that Wi-Fi works too.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
# The Duo is found by model (iPhone19,4, which is what the iPhone Duo simulator
# reports too), not name: it keeps whatever name the phone was given. Simulators
# are skipped. Pass a device name or identifier to pick one yourself.
duo=${1:-$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    h = d.get("hardwareProperties", {})
    if h.get("productType") == "iPhone19,4" and h.get("reality") != "simulated":
        print(h["udid"]); break
')}
if [[ -z "$duo" ]]; then
  echo "No iPhone Duo found. Connected devices:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Installing on $duo"
# The first build for a new phone registers it with your team (without that the
# profile "cannot be installed on this device"), and Xcode first spends minutes
# preparing the phone for development: hence the long destination timeout.
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMacDuo -configuration Release \
  -destination "platform=iOS,id=$duo" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -destination-timeout 600 build | grep -E "error:|BUILD"
xcrun devicectl device install app --device "$duo" build/Build/Products/Release-iphoneos/RemoteMacDuo.app
xcrun devicectl device process launch --device "$duo" com.bgrayson.remotemac.duo || true
