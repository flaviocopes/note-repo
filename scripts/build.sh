#!/bin/zsh
# Builds build/NoteRepo.app for Apple silicon and Intel, with the noterepo CLI inside, ad-hoc signed.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/NoteRepoCore/Version.swift)
app=build/NoteRepo.app
products=.build/apple/Products/Release

swift build -c release --arch arm64 --arch x86_64 --product NoteRepoApp
swift build -c release --arch arm64 --arch x86_64 --product noterepo

rm -rf "$app" build/AppIcon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" build/AppIcon.iconset
cp "$products/NoteRepoApp" "$app/Contents/MacOS/NoteRepo"
cp "$products/noterepo" "$app/Contents/Resources/bin/noterepo"
sed "s/__VERSION__/$version/g" resources/Info.plist > "$app/Contents/Info.plist"

for size in 16 32 128 256 512; do
  sips -z $size $size resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$app/Contents/Resources/bin/noterepo"
codesign --force --deep --sign - "$app"
echo "Built $app $version for $(lipo -archs "$app/Contents/MacOS/NoteRepo")"
