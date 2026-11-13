#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CodeIsland Debian Deployment Script (Triggered by Webhook)
# ==============================================================================
# Arguments passed by webhook:
#   $1: version (e.g. 1.0.41)
#   $2: tag (e.g. v1.0.41)
#   $3: repository (optional, default: fzrsahi/CodeIsland)
#   $4: expected_sha256 (optional)
# ==============================================================================

VERSION="${1:-}"
VERSION="${VERSION#[vV]}"
TAG="${2:-v$VERSION}"
REPO="${3:-fzrsahi/CodeIsland}"
EXPECTED_SHA="${4:-}"

WEB_ROOT="/var/www/codeisland-updates"
RELEASES_DIR="$WEB_ROOT/releases"
TARGET_DIR="$RELEASES_DIR/$VERSION"

echo "======================================================"
echo "Starting CodeIsland Update Deployment: $VERSION ($TAG)"
echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "======================================================"

# 1. Validation (Fail Early & Fail Loud)
if [[ -z "$VERSION" ]]; then
    echo "ERROR: Version argument is empty." >&2
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "ERROR: Version '$VERSION' does not match SemVer pattern (e.g. 1.0.41)." >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

BASE_URL="https://github.com/$REPO/releases/download/$TAG"
DMG_URL="$BASE_URL/CodeIsland.dmg"
APPCAST_URL="$BASE_URL/appcast.xml"
SHA256_URL="$BASE_URL/SHA256SUMS.txt"

# 2. Fetch Release Assets
echo "==> Downloading release artifacts from $BASE_URL ..."

echo "--> Fetching CodeIsland.dmg ..."
curl -fsSL "$DMG_URL" -o CodeIsland.dmg

echo "--> Fetching SHA256SUMS.txt ..."
if curl -fsSL "$SHA256_URL" -o SHA256SUMS.txt 2>/dev/null; then
    echo "Verifying SHA256 checksum..."
    sha256sum -c SHA256SUMS.txt || {
        echo "ERROR: SHA256 checksum mismatch for CodeIsland.dmg!" >&2
        rm -rf "$TARGET_DIR"
        exit 1
    }
elif [[ -n "$EXPECTED_SHA" ]]; then
    echo "Verifying against expected SHA256: $EXPECTED_SHA"
    ACTUAL_SHA="$(sha256sum CodeIsland.dmg | awk '{print $1}')"
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        echo "ERROR: SHA256 mismatch (Expected: $EXPECTED_SHA, Got: $ACTUAL_SHA)" >&2
        rm -rf "$TARGET_DIR"
        exit 1
    fi
fi

echo "--> Fetching appcast.xml ..."
if curl -fsSL "$APPCAST_URL" -o appcast.xml 2>/dev/null; then
    echo "Downloaded new appcast.xml from release."
else
    echo "Notice: appcast.xml not in release asset; checking repository raw feed..."
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/appcast.xml" -o appcast.xml || true
fi

# 3. Atomic Web Root Updates
echo "==> Performing atomic web root symlink & feed swap ..."

# Update root latest.dmg symlink
ln -sfn "releases/$VERSION/CodeIsland.dmg" "$WEB_ROOT/latest.dmg"

# Atomically update appcast.xml if downloaded
if [[ -s "$TARGET_DIR/appcast.xml" ]]; then
    cp "$TARGET_DIR/appcast.xml" "$WEB_ROOT/appcast.xml.tmp"
    mv -f "$WEB_ROOT/appcast.xml.tmp" "$WEB_ROOT/appcast.xml"
    chmod 644 "$WEB_ROOT/appcast.xml"
fi

# Ensure permissions are correct for Nginx
chmod 644 "$TARGET_DIR/CodeIsland.dmg"

# 4. Storage Retention Policy (Keep last 5 releases)
echo "==> Applying release retention policy (retaining last 5 releases) ..."
shopt -s nullglob
release_dirs=( "$RELEASES_DIR"/*/ )
shopt -u nullglob

if [[ ${#release_dirs[@]} -gt 5 ]]; then
    cd "$RELEASES_DIR"
    ls -dt */ | tail -n +6 | while read -r old_release; do
        echo "Pruning older release: $old_release"
        rm -rf "$old_release"
    done
else
    echo "Currently retaining ${#release_dirs[@]} releases (threshold is 5). No pruning required."
fi

echo "======================================================"
echo "Deployment of CodeIsland v$VERSION Completed Successfully!"
echo "Active latest: $(readlink "$WEB_ROOT/latest.dmg")"
echo "======================================================"
