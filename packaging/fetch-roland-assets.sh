#!/bin/sh
# Takes the web app and icon out of Roland's BOSS TONE STUDIO for KATANA MkII 2.1.0 macOS installer without
# installing it: Roland's app is x86_64 only and would need Rosetta. Personal use; the output is never committed.
# The installer zip is kept as the backup copy, so a rebuild works even if Roland takes the download down.
#
#   packaging/fetch-roland-assets.sh [output dir, default build/roland]
set -eu

URL=https://static.roland.com/assets/media/zip/bts_katana2_m210.zip
SHA256=f3513e87fa863b067a073081e70f9b54d753b477a04ba38877629a2ae39689b8
APP="BOSS TONE STUDIO for KATANA MkII.app"
OUT=${1:-build/roland}
ZIP="$OUT/bts_katana2_m210.zip"

verified() { [ -f "$ZIP" ] && echo "$SHA256  $ZIP" | shasum -a 256 -c - > /dev/null 2>&1; }

[ -f "$OUT/html/index.html" ] && [ -f "$OUT/AppIcon.icns" ] && verified && exit 0

mkdir -p "$OUT"
if ! verified; then
    curl -fsSL -o "$ZIP" "$URL"
    verified || { echo "Error: $ZIP does not match the expected SHA-256" >&2; exit 1; }
fi
rm -rf "$OUT/html" "$OUT/AppIcon.icns" "$OUT/zip" "$OUT/pkg"
unzip -q "$ZIP" -d "$OUT/zip"
pkgutil --expand-full "$(find "$OUT/zip" -name '*.pkg' | head -1)" "$OUT/pkg"
RESOURCES=$(find "$OUT/pkg" -type d -path "*/$APP/Contents/Resources" | head -1)
cp -R "$RESOURCES/html" "$OUT/html"
cp "$RESOURCES/AppIcon.icns" "$OUT/AppIcon.icns"
rm -rf "$OUT/zip" "$OUT/pkg"
echo "Roland's web app and icon are in $OUT (installer kept: $ZIP)"
