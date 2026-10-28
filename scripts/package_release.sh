#!/bin/bash
# Build and package a local ad hoc Release app. No distribution signing,
# notarization, Gatekeeper changes, or quarantine removal is performed.
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skip_build=false
if [[ "${1:-}" == "--skip-build" ]]; then
    skip_build=true
    shift
elif [[ "${1:-}" == "--help" ]]; then
    echo "Usage: scripts/package_release.sh [--skip-build]"
    echo "Builds Release with local ad hoc signing, verifies Sandbox, then writes ZIP/SHA-256 to .build/releases/."
    echo "--skip-build packages an already-built local ad hoc Release app."
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "Unknown argument. Use --help." >&2
    exit 2
fi
cd "$repository"
output="$repository/.build/releases"
mkdir -p "$output"
/usr/bin/security find-identity -v -p codesigning > "$output/signing-identities.txt" 2>&1 || true

if [[ "$skip_build" != true ]]; then
    /usr/bin/xcodebuild -project PersonalSpace.xcodeproj -scheme PersonalSpace \
        -configuration Release -destination 'platform=macOS' \
        -derivedDataPath .build/DerivedData \
        -clonedSourcePackagesDirPath .build/SourcePackages \
        'CODE_SIGN_IDENTITY=-' 'CODE_SIGN_STYLE=Manual' 'ONLY_ACTIVE_ARCH=YES' build
fi

app="$repository/.build/DerivedData/Build/Products/Release/PersonalSpace.app"
if [[ ! -d "$app" ]]; then
    echo "Release app not found. Run this script without --skip-build after integrating the AppIcon catalog." >&2
    exit 3
fi
info="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
architecture=$(/usr/bin/lipo -archs "$app/Contents/MacOS/$executable" | /usr/bin/tr ' ' '-')
timestamp=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
name="PersonalSpace-$version-$build-local-$architecture-$timestamp"
staging=$(/usr/bin/mktemp -d "$output/.package.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
/usr/bin/codesign --display --verbose=2 "$app" > "$staging/signature.txt" 2>&1
if ! /usr/bin/grep -q '^Signature=adhoc$' "$staging/signature.txt"; then
    echo "This packaging path expects a local ad hoc Release build. Rebuild without --skip-build." >&2
    exit 4
fi
/usr/bin/codesign --display --entitlements :- "$app" > "$staging/entitlements.plist" 2> "$staging/entitlements-command.txt"
sandbox=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$staging/entitlements.plist")
if [[ "$sandbox" != true ]]; then
    echo "App Sandbox entitlement is missing; package refused." >&2
    exit 5
fi
if [[ ! -f "$app/Contents/Resources/AppIcon.icns" ]]; then
    echo "Compiled AppIcon.icns is missing; integrate Assets.xcassets in the app resources and rebuild." >&2
    exit 6
fi

archive="$output/$name.zip"
if [[ -e "$archive" ]]; then
    echo "Archive already exists; run again to get a new timestamp." >&2
    exit 7
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$output" && /usr/bin/shasum -a 256 "$name.zip" > "$name.zip.sha256")
/usr/bin/unzip -tq "$archive"

metadata="$output/$name-metadata"
mkdir "$metadata"
cp "$staging/signature.txt" "$staging/entitlements.plist" "$output/signing-identities.txt" "$metadata/"
cp RELEASE_NOTES.md "$metadata/RELEASE_NOTES.md"
cat > "$metadata/LOCAL-BUILD.txt" <<EOF
PersonalSpace $version ($build)
Built architecture: $architecture
Packaged at UTC: $timestamp
Signature: local ad hoc; App Sandbox verified

This is a local development build. This script did not perform Developer ID
signing, notarization, DMG creation, or clean-account installation validation.
macOS can reject this archive on another Mac. No Gatekeeper or quarantine
setting has been changed. Build from the source project in Xcode when needed.

ZIP integrity was checked with unzip -tq. Verify downloaded bytes using the
sibling .zip.sha256 file. Code signing and SHA-256 do not replace notarization.
The read-only certificate inventory is in signing-identities.txt.
EOF
echo "Local Release ZIP: $archive"
echo "SHA-256: $archive.sha256"
echo "Package metadata: $metadata"
echo "Developer ID signing/notarization/DMG: not performed."
