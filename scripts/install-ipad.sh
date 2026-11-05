#!/bin/zsh
# Signs with your developer team and installs straight onto a connected iPad.
# First time: plug the iPad in by USB, unlock it, tap Trust, and turn on
# Settings > Privacy & Security > Developer Mode. After that Wi-Fi works too.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
# Found from devicectl's JSON, as in install-duo.sh: its table has changed
# columns before, and "unavailable" contains "available". Simulators are
# skipped, and so is an iPad this Mac can't reach right now, which xcodebuild
# would otherwise wait on until it timed out. Pass a device name or identifier
# to pick one yourself.
ipad=${1:-$(xcrun devicectl list devices -j /dev/stdout 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    h = d.get("hardwareProperties", {})
    if (h.get("productType", "").startswith("iPad") and h.get("reality") != "simulated"
            and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"):
        print(h["udid"]); break
')}
if [[ -z "$ipad" ]]; then
  echo "No reachable iPad. Plug it in by USB and unlock it. Devices:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi
echo "Installing on $ipad"
# -allowProvisioningUpdates registers the iPad with your team and makes the profile.
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMac -configuration Release \
  -destination "platform=iOS,id=$ipad" -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -destination-timeout 600 build | grep -E "error:|BUILD"
xcrun devicectl device install app --device "$ipad" build/Build/Products/Release-iphoneos/RemoteMac.app
xcrun devicectl device process launch --device "$ipad" com.bgrayson.remotemac.ipad || true
