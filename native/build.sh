#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
app="build/NoteRepo Native.app"

swift build -c release --product NoteRepo

rm -rf "$app" build/AppIcon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/AppIcon.iconset
cp .build/release/NoteRepo "$app/Contents/MacOS/NoteRepo"
cp Info.plist "$app/Contents/Info.plist"

for size in 16 32 128 256 512; do
  sips -z $size $size ../resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) ../resources/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$app"
echo "Built $app"
