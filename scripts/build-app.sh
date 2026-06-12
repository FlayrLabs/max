#!/bin/zsh
# Builds AskMax.app from the SwiftPM executable. No Xcode project needed.
#
# Signing:
#   - Default: stable self-signed "AskMax Local Signing" (permissions persist
#     across rebuilds; fine for local use, but other Macs will warn on first open).
#   - For distribution: set DEVELOPER_ID to your "Developer ID Application: …"
#     identity to produce a notarization-ready, hardened-runtime build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/AskMax.app"

echo "▸ swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AskMax"

# Regenerate the icon if missing.
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || "$ROOT/scripts/make-icon.sh"
# Regenerate the transparent inline glyph if missing.
[[ -f "$ROOT/Resources/DuckGlyph.png" ]] || swift "$ROOT/scripts/make-glyph.swift" >/dev/null

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AskMax"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/DuckGlyph.png" "$APP/Contents/Resources/DuckGlyph.png"

ENTITLEMENTS="$ROOT/Resources/AskMax.entitlements"
TEAM_ID="${TEAM_ID:-NRNU83UJ68}"   # Apple Team ID (from the poundcake account)

# Auto-detect an installed Developer ID Application cert if DEVELOPER_ID unset.
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ codesign (Developer ID: $DEVELOPER_ID) + hardened runtime"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"
    echo "✓ signed $APP"

    if [[ -n "${APPLE_ID:-}" && -n "${APP_PW:-}" ]]; then
        echo "▸ notarizing (team $TEAM_ID) — this can take a few minutes"
        ditto -c -k --keepParent "$APP" /tmp/AskMax-notarize.zip
        xcrun notarytool submit /tmp/AskMax-notarize.zip \
            --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait
        xcrun stapler staple "$APP"
        rm -f /tmp/AskMax-notarize.zip
        echo "✓ notarized + stapled $APP"
    else
        echo ""
        echo "To notarize (set APPLE_ID + APP_PW — an app-specific password):"
        echo "  ditto -c -k --keepParent \"$APP\" /tmp/AskMax.zip"
        echo "  xcrun notarytool submit /tmp/AskMax.zip --apple-id <you> --team-id $TEAM_ID --password <app-specific-pw> --wait"
        echo "  xcrun stapler staple \"$APP\""
    fi
else
    "$ROOT/scripts/make-signing-cert.sh" >/dev/null 2>&1 || true
    IDENTITY="AskMax Local Signing"
    if codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP" 2>/dev/null; then
        echo "▸ codesign (stable identity: $IDENTITY) + hardened runtime"
    else
        echo "▸ codesign (ad-hoc — permissions will reset each build)"
        codesign --force --deep --sign - "$APP"
    fi
    echo "✓ built $APP"
fi
