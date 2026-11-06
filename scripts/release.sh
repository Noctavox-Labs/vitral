#!/bin/zsh
# Builds the Vitral that people download: signed with Developer ID, notarized by Apple and with
# the Sparkle feed that lets it update itself.
#   scripts/release.sh   → .build/release/<version>/Vitral-<version>.dmg, appcast.xml, notes
#   NOTARIZE=0 scripts/release.sh   only builds and signs, to check the signatures (not for people).
# Then publish with the gh command it prints (a person decides when).
#
# Needs, on this Mac:
#   - the "Developer ID Application" certificate in the keychain;
#   - notarytool credentials saved as the profile "vitral" (NOTARY_PROFILE to change it):
#       xcrun notarytool store-credentials vitral --apple-id <Apple ID> --team-id 8922S5NL5T
#   - Sparkle's private key in the keychain, account "vitral" (generate_keys --account vitral);
#     its public half is SUPublicEDKey in project.yml. Losing it means the published copies can no
#     longer update: keep an export of it somewhere safe (generate_keys --account vitral -x <file>).
#   - release-notes/<version>.md (English, then Spanish): what changed, shown by the updater.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=8922S5NL5T
ID="Developer ID Application: Javier Vargas ($TEAM)"
PROFILE=${NOTARY_PROFILE:-vitral}
REPO=noctavox-labs/vitral

say() { print -r -- "[$(date +%H:%M:%S)] $*" >&2 }
fail() { say "ERROR: $*"; exit 1 }

security find-identity -v -p codesigning | grep -qF "$ID" || fail "missing the certificate: $ID"
NOTARIZE=${NOTARIZE:-1}
[[ $NOTARIZE == 0 ]] || xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool profile \"$PROFILE\" (xcrun notarytool store-credentials $PROFILE --apple-id … --team-id $TEAM)"
[[ -z $(git status --porcelain -- Sources App project.yml) ]] || fail "uncommitted changes in Sources, App or project.yml"

# --- Build ------------------------------------------------------------------------------------
say "building"
xcodegen generate --quiet
derived=.build/xcode-release
xcodebuild -project Vitral.xcodeproj -scheme Vitral -configuration Release \
    -derivedDataPath $derived -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY="$ID" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp build \
    | grep -E "error:|BUILD" || true
built=$derived/Build/Products/Release/Vitral.app
[[ -x $built/Contents/MacOS/vitral-launcher ]] || fail "the build failed"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$built/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$built/Contents/Info.plist")
key=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$built/Contents/Info.plist")
[[ -n $key ]] || fail "SUPublicEDKey is missing"
notes=release-notes/$version.md
[[ -f $notes ]] || fail "missing $notes"
# The launcher compares the version it was built with (Vitral.version) with the installed
# Vitral's to take its launcher: they must be the same, or every app would think it is behind.
code=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/VitralKit/Vitral.swift)
[[ $code == "$version" ]] || fail "Vitral.version is \"$code\", but the app is $version (project.yml)"

out=.build/release/$version
rm -rf "$out" && mkdir -p "$out"
app=$out/Vitral.app
ditto "$built" "$app"

# --- Sign, inside out (Sparkle's helpers too: notarization needs every binary signed with the
# hardened runtime and a timestamp). No --deep: it would sign each piece the same way. ----------
say "signing $version ($build)"
sign() { codesign --force --sign "$ID" --options runtime --timestamp "$@" }
fw=$app/Contents/Frameworks/Sparkle.framework/Versions/B
for xpc in "$fw"/XPCServices/*.xpc(N); do sign --preserve-metadata=entitlements "$xpc"; done
sign "$fw/Autoupdate"
sign "$fw/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/MacOS/vitral-launcher"
sign "$app"
codesign --verify --strict --deep "$app" || fail "the signature does not verify"

# --- Notarize the app and staple its ticket (so it opens without a network check) -----------
notarize() {  # notarize <file>
    [[ $NOTARIZE == 0 ]] && { say "skipping notarization of $(basename "$1")"; return; }
    say "notarizing $(basename "$1") (a few minutes)"
    local result
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
    print -r -- "$result" | grep -q '"status" *: *"Accepted"' || {
        print -r -- "$result" >&2
        local id=$(print -r -- "$result" | sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' | head -1)
        [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
        fail "Apple did not accept $(basename "$1")"
    }
}
ditto -c -k --keepParent "$app" "$out/Vitral-app.zip"
notarize "$out/Vitral-app.zip"
rm "$out/Vitral-app.zip"
[[ $NOTARIZE == 0 ]] || xcrun stapler staple -q "$app"

# --- Disk image, signed, notarized and stapled -------------------------------------------------
dmg=$out/Vitral-$version.dmg
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Vitral.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Vitral $version" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg"
codesign --force --sign "$ID" --timestamp "$dmg"
notarize "$dmg"
if [[ $NOTARIZE == 0 ]]; then
    say "not notarized: stopping before the appcast"
    exit 0
fi
xcrun stapler staple -q "$dmg"
spctl --assess --type open --context context:primary-signature "$dmg" || fail "Gatekeeper rejects the disk image"
spctl --assess --type execute "$app" || fail "Gatekeeper rejects the app"

# --- Sparkle feed: the update, its EdDSA signature and the notes -----------------------------
say "writing the appcast"
feed=$(mktemp -d)
cp "$dmg" "$feed/"
# Sparkle shows <archive name>.html as the release notes.
{
    print -r -- "<!DOCTYPE html><meta charset=\"utf-8\"><body style=\"font: 13px -apple-system\">"
    sed -E 's/&/\&amp;/g; s/</\&lt;/g; s/^## (.*)$/<h3>\1<\/h3>/; s/^- (.*)$/<li>\1<\/li>/; s/^$/<br>/' "$notes"
} > "$feed/Vitral-$version.html"
sparkle=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
"$sparkle/generate_appcast" --account vitral --embed-release-notes \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$version/" \
    --link "https://github.com/$REPO" -o "$out/appcast.xml" "$feed"
rm -rf "$feed"
grep -q 'sparkle:edSignature' "$out/appcast.xml" || fail "the appcast has no EdDSA signature"
cp "$notes" "$out/notes.md"
shasum -a 256 "$dmg" | sed 's|  .*/|  |' > "$dmg.sha256"

say "ready in $out"
cat <<EOF
To publish (marked as the latest release, so the updater finds appcast.xml):
  gh release create v$version "$dmg" "$dmg.sha256" "$out/appcast.xml" \\
      --repo $REPO --title "Vitral $version" --notes-file "$out/notes.md" --latest
EOF
