#!/bin/zsh
# Builds Vitral.app (Release) and packs it in a disk image with a link to Applications.
#   scripts/make-dmg.sh            → .build/dmg/Vitral-<version>.dmg
# Needs Xcode 26 or later and xcodegen. The app is signed ad hoc: it opens on the Mac that built
# it. To give it to other people it must be signed with Developer ID and notarized (phase 3).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
# Signed ad hoc, the hardened runtime must stay off: with it, macOS only loads libraries signed by
# the same team, and an ad hoc app has none, so Sparkle.framework would not load.
xcodebuild -project Vitral.xcodeproj -scheme Vitral -configuration Release \
    -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO build \
    | grep -E "error:|BUILD" || true

app=.build/xcode/Build/Products/Release/Vitral.app
[[ -x "$app/Contents/MacOS/vitral-launcher" ]] || { echo "Vitral.app is missing or has no launcher" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Vitral.app"
ln -s /Applications "$stage/Applications"

mkdir -p .build/dmg
dmg=.build/dmg/Vitral-$version.dmg
hdiutil create -quiet -volname "Vitral $version" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg"
echo "$PWD/$dmg"
