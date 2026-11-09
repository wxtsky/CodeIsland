#!/usr/bin/env bash
# Builds the Feishu long-connection helper that CodeIsland.app supervises.
# Usage: ./scripts/build-feishu-bridge.sh [arm64|universal]
set -euo pipefail

ARCH="${1:-arm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/helpers/feishu-bridge"
OUT="$SRC/dist"
mkdir -p "$OUT"

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go is required to build feishu-bridge" >&2
    exit 1
fi

build_one() {
    local goarch="$1"
    local dest="$2"
    echo "==> feishu-bridge $goarch"
    (
        cd "$SRC"
        CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
            go build -trimpath -ldflags "-s -w" -o "$dest" .
    )
}

case "$ARCH" in
    arm64)
        build_one arm64 "$OUT/feishu-bridge-arm64"
        ;;
    universal)
        build_one arm64 "$OUT/feishu-bridge-arm64"
        build_one amd64 "$OUT/feishu-bridge-amd64"
        lipo -create "$OUT/feishu-bridge-arm64" "$OUT/feishu-bridge-amd64" \
            -output "$OUT/feishu-bridge"
        ;;
    *)
        echo "ERROR: arch must be arm64 or universal (got '$ARCH')" >&2
        exit 1
        ;;
esac
