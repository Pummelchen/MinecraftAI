#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DMG_DIR="$BUILD_DIR/pummelchen-dmg"
STAGE_DIR="$DMG_DIR/stage"
APP_NAME="MCPummelchenModClient.app"
APP_DIR="$STAGE_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DMG_NAME="MCPummelchenModClient.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
VERSION="${PUMMELCHEN_CLIENT_VERSION:-0.8.0}"
APP_RELEASE_ID="${PUMMELCHEN_RELEASE_ID:-development}"

cd "$ROOT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

swift build -c release --product PummelchenClient
swift build -c release --product pummelchen-client-sync

rm -rf "$STAGE_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/PummelchenClient" "$MACOS_DIR/PummelchenClient"
install -m 755 "$BUILD_DIR/arm64-apple-macosx/release/pummelchen-client-sync" "$MACOS_DIR/pummelchen-client-sync"

ICON_SRC="$ROOT_DIR/Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
fi

DUCKDB_LIB="${PUMMELCHEN_DUCKDB_DYLIB:-/opt/homebrew/lib/libduckdb.dylib}"
if [[ ! -f "$DUCKDB_LIB" ]]; then
    echo "libduckdb.dylib not found; install DuckDB or set PUMMELCHEN_DUCKDB_DYLIB" >&2
    exit 1
fi
DUCKDB_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$DUCKDB_LIB")"
DUCKDB_INSTALL_NAME="$(otool -D "$DUCKDB_REAL" | tail -n 1)"
install -m 755 "$DUCKDB_REAL" "$FRAMEWORKS_DIR/libduckdb.dylib"
install_name_tool -id "@rpath/libduckdb.dylib" "$FRAMEWORKS_DIR/libduckdb.dylib"
install_name_tool -change "$DUCKDB_INSTALL_NAME" "@rpath/libduckdb.dylib" "$MACOS_DIR/PummelchenClient"
install_name_tool -change "$DUCKDB_INSTALL_NAME" "@rpath/libduckdb.dylib" "$MACOS_DIR/pummelchen-client-sync"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/PummelchenClient"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/pummelchen-client-sync"
DUCKDB_PREFIX="$(cd "$(dirname "$DUCKDB_REAL")/.." && pwd)"
if [[ -f "$DUCKDB_PREFIX/LICENSE" ]]; then
    install -m 644 "$DUCKDB_PREFIX/LICENSE" "$RESOURCES_DIR/duckdb-LICENSE.txt"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>MCPummelchenModClient</string>
    <key>CFBundleExecutable</key>
    <string>PummelchenClient</string>
    <key>CFBundleIdentifier</key>
    <string>de.pummelchen.minecraft.client</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>MCPummelchenModClient</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>PummelchenReleaseID</key>
    <string>$APP_RELEASE_ID</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOSX_DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$FRAMEWORKS_DIR/libduckdb.dylib"
codesign --force --sign - "$MACOS_DIR/pummelchen-client-sync"
codesign --force --sign - "$MACOS_DIR/PummelchenClient"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

hdiutil create \
    -volname "MCPummelchenModClient" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

(
    cd "$DMG_DIR"
    shasum -a 256 "$DMG_NAME" | tee "$DMG_NAME.sha256"
)

if [[ -n "${PUMMELCHEN_RELEASE_ID:-}" ]]; then
    SERVER_PACKAGE_DIR="${PUMMELCHEN_SERVER_PACKAGE_DIR:-$ROOT_DIR/../../Server App/MCPummelchenModServer}"
    SOAK_ARGS=(
        --dmg "$DMG_PATH"
        --release-id "$PUMMELCHEN_RELEASE_ID"
        --server-address "${PUMMELCHEN_SERVER_ADDRESS:-91.99.176.243:25565}"
        --server-url "${PUMMELCHEN_SERVER_URL:-https://pummelchen.91.99.176.243.nip.io}"
        --duration-seconds "${PUMMELCHEN_HEADLESS_SOAK_SECONDS:-300}"
    )
    if [[ -n "${PUMMELCHEN_HEADLESS_COMMAND:-}" ]]; then
        SOAK_ARGS+=(--headless-command "$PUMMELCHEN_HEADLESS_COMMAND")
    fi
    swift run \
        --package-path "$SERVER_PACKAGE_DIR" \
        -c release \
        pummelchen-headless-soak \
        "${SOAK_ARGS[@]}"
elif [[ "${PUMMELCHEN_REQUIRE_HEADLESS_SOAK:-false}" == "true" ]]; then
    echo "PUMMELCHEN_REQUIRE_HEADLESS_SOAK=true but PUMMELCHEN_RELEASE_ID is missing" >&2
    exit 1
fi

echo "$DMG_PATH"
