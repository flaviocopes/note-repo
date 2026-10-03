#!/bin/zsh
# Builds NoteRepo, notarizes it with Apple, staples the ticket, and writes dist/NoteRepo-<version>.zip for the GitHub release.
# Needs the Developer ID certificate in the keychain and a notarytool profile named "notary":
#   xcrun notarytool store-credentials notary --apple-id <apple id> --team-id DGFKNTAG99
set -euo pipefail

cd "$(dirname "$0")/.."
scripts/build.sh
version=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/NoteRepoCore/Version.swift)
app=build/NoteRepo.app
zip=dist/NoteRepo-$version.zip

if [[ $(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p') != DGFKNTAG99 ]]; then
  echo "$app isn't signed with the Developer ID certificate, so Apple won't notarize it." >&2
  exit 1
fi

mkdir -p dist
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
result=$(xcrun notarytool submit "$zip" --keychain-profile notary --wait --output-format json)
if [[ $(plutil -extract status raw -o - - <<< "$result") != Accepted ]]; then
  echo "$result" >&2
  xcrun notarytool log "$(plutil -extract id raw -o - - <<< "$result")" --keychain-profile notary >&2
  exit 1
fi

xcrun stapler staple "$app"
rm "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
spctl --assess --type execute --verbose "$app"
echo "Notarized $zip"
