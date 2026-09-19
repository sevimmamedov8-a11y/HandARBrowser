#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
rm -rf build
mkdir -p build

# Build the target directly. We intentionally do not pass -derivedDataPath,
# because current xcodebuild requires a scheme when that option is used.
xcodebuild \
  -project HandARBrowser.xcodeproj \
  -target HandARBrowser \
  -configuration Release \
  -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$ROOT/build/App" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="$ROOT/build/App/HandARBrowser.app"
test -d "$APP"
rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/
cd build
/usr/bin/zip -qry HandARBrowser-unsigned.ipa Payload
cd "$ROOT"

echo "Created: $ROOT/build/HandARBrowser-unsigned.ipa"
