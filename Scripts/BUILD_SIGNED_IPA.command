#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
read "TEAM?Apple Developer Team ID (10 chars): "
if [[ -z "${TEAM}" ]]; then echo "Team ID is required"; exit 1; fi
rm -rf build
mkdir -p build
xcodebuild -project HandARBrowser.xcodeproj \
  -target HandARBrowser \
  -configuration Release \
  -sdk iphoneos \
  -archivePath build/HandARBrowser.xcarchive \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  archive
rm -rf build/Payload
mkdir build/Payload
cp -R build/HandARBrowser.xcarchive/Products/Applications/HandARBrowser.app build/Payload/
cd build
/usr/bin/zip -qry HandARBrowser-signed.ipa Payload
cd "$ROOT"
echo "Created: $ROOT/build/HandARBrowser-signed.ipa"
