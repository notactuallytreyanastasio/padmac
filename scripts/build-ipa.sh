#!/bin/zsh
# Builds an UNSIGNED RemoteMac.ipa for Sideloadly / AltStore, which re-sign it
# with your Apple ID when installing.
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate -q
xcodebuild -project RemoteMac.xcodeproj -scheme RemoteMac -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | grep -E "error:|BUILD" 
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/Build/Products/Release-iphoneos/RemoteMac.app build/ipa/Payload/
(cd build/ipa && zip -qry ../../RemoteMac.ipa Payload)
echo "Wrote $(pwd)/RemoteMac.ipa"
