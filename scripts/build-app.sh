#!/usr/bin/env bash
# Assemble a runnable .app bundle from `swift build` output.
# Requires only the macOS Command Line Tools — no full Xcode needed.
#
# Usage:
#   scripts/build-app.sh                      # release config, current arch
#   scripts/build-app.sh debug                # debug config
#   scripts/build-app.sh release universal    # universal binary (arm64 + x86_64)

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Ribbind"
BUILD_CONFIG="${1:-release}"
TARGET_ARCH="${2:-$(uname -m)}"

if [[ "$TARGET_ARCH" == "universal" ]]; then
    BUILD_FLAGS=(--arch arm64 --arch x86_64)
    # Universal swift-build output lives at .build/apple/Products/<Release|Debug>/<binary>.
    # Avoid bash 4's `${VAR^}` since macOS ships bash 3.2.
    case "$BUILD_CONFIG" in
        release) CONFIG_DIR_NAME="Release" ;;
        debug)   CONFIG_DIR_NAME="Debug" ;;
        *)       CONFIG_DIR_NAME="$BUILD_CONFIG" ;;
    esac
    PLATFORM_DIR="apple/Products/$CONFIG_DIR_NAME"
    BIN_PATH=".build/$PLATFORM_DIR/$APP_NAME"
else
    BUILD_FLAGS=()
    PLATFORM_DIR="${TARGET_ARCH}-apple-macosx/${BUILD_CONFIG}"
    BIN_PATH=".build/$PLATFORM_DIR/$APP_NAME"
fi

echo "[1/4] Building $APP_NAME ($BUILD_CONFIG, $TARGET_ARCH)..."
if [[ ${#BUILD_FLAGS[@]} -eq 0 ]]; then
    swift build -c "$BUILD_CONFIG"
else
    swift build -c "$BUILD_CONFIG" "${BUILD_FLAGS[@]}"
fi

if [[ ! -f "$BIN_PATH" ]]; then
    echo "ERROR: binary not found at $BIN_PATH" >&2
    exit 1
fi

APP_DIR="dist/$APP_NAME.app"
echo "[2/4] Assembling $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp AppBundleResources/Info.plist "$APP_DIR/Contents/Info.plist"
cp AppBundleResources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Copy any SPM-generated resource bundles next to the binary.
shopt -s nullglob
for bundle in .build/$PLATFORM_DIR/*.bundle; do
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
shopt -u nullglob

echo "[3/4] Ad-hoc code-signing with Apple Events entitlement..."
# Hardened runtime requires explicit `com.apple.security.automation.apple-events`
# to send Apple Events at runtime. Without it, AE sends silently fail under
# hardened runtime. Entitlement file at AppBundleResources/Ribbind.entitlements.
codesign --sign - --deep --force --options runtime \
    --entitlements AppBundleResources/Ribbind.entitlements \
    "$APP_DIR" 2>&1 | sed 's/^/  /'
codesign_status=${PIPESTATUS[0]}
if [[ "$codesign_status" -ne 0 ]]; then
    echo "ERROR: codesign exited with status $codesign_status — aborting build." >&2
    exit "$codesign_status"
fi

echo "[4/4] Done."
echo
echo "  Built:  $APP_DIR"
echo "  Run:    open $APP_DIR"
echo
echo "Note: macOS Gatekeeper will block ad-hoc-signed apps on first launch."
echo "      Users who download this from GitHub Releases must run:"
echo "          xattr -cr /Applications/$APP_NAME.app"
echo "      (one-time, per release)"
