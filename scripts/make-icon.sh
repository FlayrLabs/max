#!/bin/zsh
# Builds Resources/AppIcon.icns from Resources/AppIcon-source.png (1024x1024,
# the black rounded-square duck). The artwork already has the rounded shape +
# transparent corners macOS expects, so we just resize into an iconset.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/AppIcon-source.png"
ICONSET="Resources/AppIcon.iconset"
[[ -f "$SRC" ]] || { echo "missing $SRC"; exit 1; }

rm -rf "$ICONSET"; mkdir -p "$ICONSET"
typeset -A sizes=(
    icon_16x16 16  icon_16x16@2x 32
    icon_32x32 32  icon_32x32@2x 64
    icon_128x128 128  icon_128x128@2x 256
    icon_256x256 256  icon_256x256@2x 512
    icon_512x512 512  icon_512x512@2x 1024
)
for name px in ${(kv)sizes}; do
    sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "Resources/AppIcon.icns"
rm -rf "$ICONSET"
echo "✓ Resources/AppIcon.icns"
