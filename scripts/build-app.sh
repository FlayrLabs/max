#!/bin/zsh
# Builds Max.app from the SwiftPM executable. No Xcode project needed.
#
# Signing:
#   - Default: stable self-signed "Max Local Signing" (permissions persist
#     across rebuilds; fine for local use, but other Macs will warn on first open).
#   - For distribution: set DEVELOPER_ID to your "Developer ID Application: …"
#     identity to produce a notarization-ready, hardened-runtime build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/dist/Max.app"

echo "▸ swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Max"

# Regenerate the icon if missing.
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || "$ROOT/scripts/make-icon.sh"
# Regenerate the transparent inline glyph if missing.
[[ -f "$ROOT/Resources/DuckGlyph.png" ]] || swift "$ROOT/scripts/make-glyph.swift" >/dev/null

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Max"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Crash reporting (opt-out) — bake the GlitchTip DSN into the OFFICIAL build's
# Info.plist only when MAX_SENTRY_DSN is set in the environment. Source builds omit
# it entirely, so someone cloning + building Max sends no telemetry.
if [[ -n "${MAX_SENTRY_DSN:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :MaxSentryDSN string ${MAX_SENTRY_DSN}" "$APP/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :MaxSentryDSN ${MAX_SENTRY_DSN}" "$APP/Contents/Info.plist"
    echo "▸ crash reporting enabled (MaxSentryDSN injected)"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/DuckGlyph.png" "$APP/Contents/Resources/DuckGlyph.png"

# Embed Sparkle.framework (auto-updater) and add an rpath so the binary finds it
# in Contents/Frameworks at runtime (SwiftPM only bakes in @loader_path).
FRAMEWORK_SRC="$(swift build -c release --show-bin-path)/Sparkle.framework"
if [[ -d "$FRAMEWORK_SRC" ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Max" 2>/dev/null || true
    echo "▸ embedded Sparkle.framework"
fi

ENTITLEMENTS="$ROOT/Resources/Max.entitlements"
TEAM_ID="${TEAM_ID:-NRNU83UJ68}"   # Apple Team ID (from the poundcake account)

# Auto-detect an installed Developer ID Application cert if DEVELOPER_ID unset.
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
fi

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ codesign Sparkle.framework helpers + app (Developer ID: $DEVELOPER_ID) + hardened runtime"
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$FW" ]]; then
        # Notarization requires every nested executable to be signed — do them inside-out.
        for c in \
            "Versions/B/XPCServices/Downloader.xpc" \
            "Versions/B/XPCServices/Installer.xpc" \
            "Versions/B/Updater.app" \
            "Versions/B/Autoupdate"; do
            codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$FW/$c"
        done
        codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$FW"
    fi
    # Sign the app last (no --deep: the embedded framework is already signed above).
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID" "$APP"
    echo "✓ signed $APP"

    if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APP_PW:-}" ) ]]; then
        echo "▸ notarizing (team $TEAM_ID) — this can take a few minutes"
        ditto -c -k --keepParent "$APP" /tmp/Max-notarize.zip
        if [[ -n "${NOTARY_PROFILE:-}" ]]; then
            xcrun notarytool submit /tmp/Max-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
        else
            xcrun notarytool submit /tmp/Max-notarize.zip \
                --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait
        fi
        xcrun stapler staple "$APP"
        rm -f /tmp/Max-notarize.zip
        echo "✓ notarized + stapled $APP"
    else
        echo ""
        echo "To notarize: store credentials once (keeps the app-specific password in your keychain) —"
        echo "  xcrun notarytool store-credentials \"max-notary\" --apple-id <you> --team-id $TEAM_ID"
        echo "then re-run:  NOTARY_PROFILE=max-notary ./scripts/build-app.sh"
    fi
else
    "$ROOT/scripts/make-signing-cert.sh" >/dev/null 2>&1 || true
    IDENTITY="Max Local Signing"
    if codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP" 2>/dev/null; then
        echo "▸ codesign (stable identity: $IDENTITY) + hardened runtime"
    else
        echo "▸ codesign (ad-hoc — permissions will reset each build)"
        codesign --force --deep --sign - "$APP"
    fi
    echo "✓ built $APP"
fi
