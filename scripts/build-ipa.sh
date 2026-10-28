#!/bin/zsh
# Builds an UNSIGNED RemoteMac.ipa for Sideloadly / AltStore, which re-sign it
# with your Apple ID when installing. `build-ipa.sh duo` builds RemoteMacDuo.ipa,
# the iPhone Duo app, instead.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
# A bundle ID belongs to the first Apple account that signs it, so the
# project's own (com.bgrayson.remotemac.ipad) is taken. Derive one from this
# Mac's hardware ID instead: unique to you, and the same on every rebuild, so
# re-sideloading replaces the app rather than adding a second copy.
# Set REMOTEMAC_BUNDLE_ID to choose your own.
mac_id=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}' | shasum | cut -c1-8)
if [[ ${1:-} == duo ]]; then app=RemoteMacDuo kind=duo; else app=RemoteMac kind=ipad; fi
bundle_id=${REMOTEMAC_BUNDLE_ID:-io.github.remotemac.$kind-$mac_id}
xcodebuild -project RemoteMac.xcodeproj -scheme $app -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  PRODUCT_BUNDLE_IDENTIFIER=$bundle_id \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | grep -E "error:|BUILD"
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/Build/Products/Release-iphoneos/$app.app build/ipa/Payload/
(cd build/ipa && zip -qry ../../$app.ipa Payload)
echo "Wrote $(pwd)/$app.ipa (bundle ID $bundle_id)"
