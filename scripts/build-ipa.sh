#!/bin/bash
set -euo pipefail

GX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GX_WORK="$(mktemp -d "$GX_ROOT/build-ipa.XXXXXXXX")"
trap 'rm -rf -- "$GX_WORK"' EXIT
mkdir -p "$GX_ROOT/dist"

xcodebuild build \
  -project "$GX_ROOT/GX85Monitor.xcodeproj" \
  -scheme GX85Monitor \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$GX_WORK/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  | tee "$GX_ROOT/dist/device-build.log"

GX_APP="$GX_WORK/DerivedData/Build/Products/Release-iphoneos/GX85Monitor.app"
if [[ ! -d "$GX_APP" || ! -x "$GX_APP/GX85Monitor" ]]; then
  echo 'Device app bundle or executable is missing.' >&2
  exit 1
fi
GX_PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$GX_APP/Info.plist")
[[ "$GX_PLATFORM" == 'iphoneos' ]] || { echo 'Refusing to package a simulator app.' >&2; exit 1; }
GX_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$GX_APP/Info.plist")
GX_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$GX_APP/Info.plist")
[[ "$GX_VERSION" == '0.2.0' && "$GX_BUILD" == '2' ]] || { echo 'Unexpected version.' >&2; exit 1; }
lipo "$GX_APP/GX85Monitor" -verify_arch arm64
mkdir -p "$GX_WORK/Payload"
ditto "$GX_APP" "$GX_WORK/Payload/GX85Monitor.app"
GX_IPA="$GX_ROOT/dist/GX85Monitor-unsigned.ipa"
[[ ! -f "$GX_IPA" ]] || rm -f -- "$GX_IPA"
(cd "$GX_WORK" && /usr/bin/zip -qr "$GX_IPA" Payload)
/usr/bin/unzip -t "$GX_IPA"
echo "Unsigned device IPA: $GX_IPA"
shasum -a 256 "$GX_IPA" | tee "$GX_ROOT/dist/ipa-sha256.log"
python3 "$GX_ROOT/scripts/export-test-screenshots.py"
