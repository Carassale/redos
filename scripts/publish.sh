#!/bin/bash
# Publishes the output of `make release`: GitHub release with zip and dmg, then the updated appcast.
# Usage: scripts/publish.sh VERSION [beta]
set -euo pipefail

version="$1"
channel="${2:-}"
out="build/release"

[[ -f "$out/RedOS-$version.zip" && -f "$out/RedOS-$version.dmg" ]] || { echo "error: run 'make release' first"; exit 1; }
git diff --quiet HEAD -- . ':(exclude)appcast.xml' || { echo "error: uncommitted changes besides appcast.xml"; exit 1; }

flags=()
[[ "$channel" == "beta" ]] && flags+=(--prerelease)

# The tag must point at the commit the app was built from, before the appcast commit.
git push origin HEAD
gh release create "v$version" "$out/RedOS-$version.zip" "$out/RedOS-$version.dmg" \
    --target "$(git rev-parse HEAD)" --title "RedOS $version" --notes-file "$out/notes.md" ${flags[@]+"${flags[@]}"}

# Clients see the update only once the archive is downloadable.
git add appcast.xml
git commit -q -m "release: v$version"
git push origin HEAD
git fetch -q --tags
echo "Published v$version"
