#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf build
mkdir -p build
xcodebuild -project HandARBrowser.xcodeproj \
  -target HandARBrowser \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CONFIGURATION_BUILD_DIR="$ROOT/build/App" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
rm -rf build/Payload
mkdir build/Payload
cp -R build/App/HandARBrowser.app build/Payload/
cd build
/usr/bin/zip -qry HandARBrowser-unsigned.ipa Payload
cd "$ROOT"
echo "Created: $ROOT/build/HandARBrowser-unsigned.ipa"
echo "NOTE: unsigned IPAs normally require re-signing before installation."
