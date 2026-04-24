#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/build-dmg.sh <version>
# Example: ./scripts/build-dmg.sh 1.0.7

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.build"
RELEASE_DIR="$BUILD_DIR/release"
STAGING_DIR="$BUILD_DIR/dmg-staging"
APP_DIR="$STAGING_DIR/CodeIsland.app"
CONTENTS_DIR="$APP_DIR/Contents"
OUTPUT_DMG="$BUILD_DIR/CodeIsland.dmg"

echo "==> Building CodeIsland ${VERSION} (universal)"

# Build for both architectures
cd "$REPO_ROOT"
swift build -c release --arch arm64
swift build -c release --arch x86_64

ARM_DIR="$BUILD_DIR/arm64-apple-macosx/release"
X86_DIR="$BUILD_DIR/x86_64-apple-macosx/release"

echo "==> Assembling .app bundle"

# Clean and recreate staging
rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
mkdir -p "$CONTENTS_DIR/Helpers"
mkdir -p "$CONTENTS_DIR/Resources"

# Create universal binaries
lipo -create "$ARM_DIR/CodeIsland" "$X86_DIR/CodeIsland" \
     -output "$CONTENTS_DIR/MacOS/CodeIsland"
lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
     -output "$CONTENTS_DIR/Helpers/codeisland-bridge"

# Write Info.plist (use the root Info.plist as base, update version)
CURRENT_VER=$(defaults read "$REPO_ROOT/Info.plist" CFBundleShortVersionString)
sed -e "s/<string>${CURRENT_VER}<\/string>/<string>${VERSION}<\/string>/g" \
    "$REPO_ROOT/Info.plist" > "$CONTENTS_DIR/Info.plist"

# Compile app icon and asset catalog
xcrun actool \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /dev/null \
    --compile "$CONTENTS_DIR/Resources" \
    "$REPO_ROOT/Assets.xcassets" \
    "$REPO_ROOT/AppIcon.icon"

# Copy SPM resource bundles into Contents/Resources/ — putting them at the .app
# root breaks Developer ID signing with "unsealed contents present in the bundle
# root". Bundle.module already checks resourceURL, so this layout loads fine.
for bundle in "$BUILD_DIR"/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$CONTENTS_DIR/Resources/"
        break
    fi
done

# ---------------------------------------------------------------------------
# Embed Sparkle.framework (universal, Sparkle-Project-signed via Apple Dev ID).
# The xcframework slice already contains the signed Autoupdate / Updater.app /
# XPC services, so we keep those signatures intact and sign only the outer
# bundle below — never pass --deep/--force through the framework.
# ---------------------------------------------------------------------------
mkdir -p "$CONTENTS_DIR/Frameworks"
SPARKLE_SRC="$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: $SPARKLE_SRC not found. Run 'swift build -c release' first to let SwiftPM resolve Sparkle." >&2
    exit 1
fi
rm -rf "$CONTENTS_DIR/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_SRC" "$CONTENTS_DIR/Frameworks/"
echo "==> Embedded Sparkle.framework from $SPARKLE_SRC"

# SwiftPM builds binaries with @loader_path as the only non-system rpath, which
# resolves Sparkle when the .dylib sits next to the executable (as it does
# inside .build/). Inside a real .app the binary lives in Contents/MacOS while
# the framework lives in Contents/Frameworks, so we add @executable_path/..
# /Frameworks explicitly. Changing the load commands invalidates any prior
# signature — we re-sign below.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$CONTENTS_DIR/MacOS/CodeIsland"
echo "==> Added @executable_path/../Frameworks rpath to CodeIsland binary"

echo "==> App bundle assembled at $APP_DIR"

# ---------------------------------------------------------------------------
# Developer ID signing. Skippable via SKIP_SIGN=1 for local dev builds.
# Override the identity with SIGN_IDENTITY=... if you have a different cert.
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: xuteng wang (K46MBL36P8)}"
if [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "==> SKIP_SIGN=1 — leaving adhoc signature"
elif security find-identity -v -p codesigning | grep -q "$(printf '%s' "$SIGN_IDENTITY" | sed 's/[][\\.^$*/]/\\&/g')"; then
    echo "==> Signing with '$SIGN_IDENTITY' (inside-out for Sparkle, then outer bundle)"
    SPARKLE_FW="$CONTENTS_DIR/Frameworks/Sparkle.framework"
    SPARKLE_B="$SPARKLE_FW/Versions/B"

    # Inside-out: seal Sparkle's inner components with our identity first so
    # hardened runtime + notarization accept them. --force replaces the adhoc
    # signature SwiftPM left in place. No --deep at any step — we walk the
    # tree ourselves to keep ordering explicit.
    for xpc in "$SPARKLE_B"/XPCServices/*.xpc; do
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$xpc"
    done
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_B/Autoupdate"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_B/Updater.app"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"

    # Bundled helpers (hook bridge) also need a proper signature before the
    # outer bundle is sealed, otherwise codesign's nested check rejects the
    # parent with "code object is not signed at all / In subcomponent: ...".
    for helper in "$CONTENTS_DIR"/Helpers/*; do
        [ -f "$helper" ] || continue
        codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" "$helper"
    done

    # Finally, sign the main bundle. Entitlements only on the top-level app —
    # Sparkle components have their own entitlements baked into their signatures.
    codesign --force --options runtime --timestamp \
        --entitlements "$REPO_ROOT/CodeIsland.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$APP_DIR"

    echo "==> Verifying nested signatures"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "==> Developer ID identity '$SIGN_IDENTITY' not in keychain — leaving adhoc signature"
    echo "    (install your Developer ID cert or set SIGN_IDENTITY=...)"
fi

echo "==> Creating DMG"

# Remove previous DMG if exists
rm -f "$OUTPUT_DMG"

create-dmg \
    --volname "CodeIsland ${VERSION}" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "CodeIsland.app" 175 190 \
    --hide-extension "CodeIsland.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    --sandbox-safe \
    "$OUTPUT_DMG" \
    "$STAGING_DIR/"

# ---------------------------------------------------------------------------
# Notarize + staple. Uses the "CodeIsland" keychain profile by default
# (xcrun notarytool store-credentials CodeIsland ...). Skippable via
# SKIP_NOTARIZE=1 for local dev builds. Override with NOTARY_PROFILE=....
# ---------------------------------------------------------------------------
NOTARY_PROFILE="${NOTARY_PROFILE:-CodeIsland}"
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> SKIP_NOTARIZE=1 — release DMG is not notarized"
elif [ "${SKIP_SIGN:-0}" = "1" ]; then
    echo "==> Skipping notarization (app was not Developer-ID signed)"
else
    echo "==> Submitting to Apple notary service (profile '$NOTARY_PROFILE')"
    if xcrun notarytool submit "$OUTPUT_DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        xcrun stapler staple "$OUTPUT_DMG"
    else
        echo "==> Notarization failed — inspect the log above and, if missing, run:"
        echo "    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <team> --password <app-specific>"
        exit 1
    fi
fi

echo "==> Done: $OUTPUT_DMG"

if [ "${SKIP_SIGN:-0}" != "1" ] && [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo ""
    echo "==> Release checklist:"
    echo "    1. gh release create v${VERSION} --notes '…' \"$OUTPUT_DMG\""
    echo "    2. ./scripts/update-appcast.sh ${VERSION} \"$OUTPUT_DMG\""
    echo "    3. git add appcast.xml && git commit -m 'release: v${VERSION}' && git push"
fi
