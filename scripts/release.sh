#!/bin/bash
# Packages build/RedOS.app (zip for Sparkle, dmg for first installs) and adds it to appcast.xml.
# Usage: scripts/release.sh VERSION BUILD [beta]
set -euo pipefail

version="$1"
build="$2"
channel="${3:-}"
repo="Carassale/redos"
out="build/release"
zip="RedOS-$version.zip"
dmg="RedOS-$version.dmg"
sparkle_bin=".build/artifacts/sparkle/Sparkle/bin"

plist_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" build/RedOS.app/Contents/Info.plist)
[[ "$plist_build" == "$build" ]] || { echo "error: app build $plist_build, expected $build"; exit 1; }
codesign --verify --deep --strict build/RedOS.app

rm -rf "$out" && mkdir -p "$out/dmg"
ditto -c -k --sequesterRsrc --keepParent build/RedOS.app "$out/$zip"
cp -R build/RedOS.app "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -quiet -volname "RedOS $version" -srcfolder "$out/dmg" -ov -format UDZO "$out/$dmg"
rm -rf "$out/dmg"

# Prints: sparkle:edSignature="..." length="..."; CI passes the key as a file, locally it is in the Keychain.
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    signature=$("$sparkle_bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$out/$zip")
else
    signature=$("$sparkle_bin/sign_update" --account redos "$out/$zip")
fi

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
git log --no-merges --pretty='%s' ${last_tag:+"$last_tag"..}HEAD | grep -v '^release: ' > "$out/notes.md" || true

python3 scripts/appcast.py appcast.xml \
    --version "$version" --build "$build" --channel "$channel" \
    --url "https://github.com/$repo/releases/download/v$version/$zip" \
    --signature "$signature" --notes "$out/notes.md"

echo "Ready: $out/$zip, $out/$dmg, appcast.xml (channel: ${channel:-stable}). Next: make publish"
