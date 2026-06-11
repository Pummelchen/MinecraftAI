#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
APP_NAME="Pummelchen Installer.app"
DMG_NAME="Pummelchen-Client-Installer.dmg"
SWIFT_SOURCE="$ROOT_DIR/client-installer/ProgressInstaller.swift"
BOOTSTRAP_SOURCE="$ROOT_DIR/client-installer/install-bootstrap.sh"

command -v hdiutil >/dev/null 2>&1 || {
  echo "hdiutil is required; build this DMG on macOS." >&2
  exit 1
}

command -v swiftc >/dev/null 2>&1 || {
  echo "swiftc is required; install Xcode Command Line Tools." >&2
  exit 1
}

[ -f "$SWIFT_SOURCE" ] || {
  echo "Missing Swift installer source: $SWIFT_SOURCE" >&2
  exit 1
}

[ -f "$BOOTSTRAP_SOURCE" ] || {
  echo "Missing installer bootstrap script: $BOOTSTRAP_SOURCE" >&2
  exit 1
}

rm -rf "$OUTPUT_DIR/build"
mkdir -p "$OUTPUT_DIR/build/$APP_NAME/Contents/MacOS" "$OUTPUT_DIR/build/$APP_NAME/Contents/Resources"

cat > "$OUTPUT_DIR/build/$APP_NAME/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Pummelchen Installer</string>
  <key>CFBundleIdentifier</key>
  <string>server.pummelchen.client-installer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Pummelchen Installer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.2</string>
  <key>CFBundleVersion</key>
  <string>5</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

swiftc "$SWIFT_SOURCE" \
  -o "$OUTPUT_DIR/build/$APP_NAME/Contents/MacOS/Pummelchen Installer" \
  -framework AppKit

install -m 0755 "$BOOTSTRAP_SOURCE" "$OUTPUT_DIR/build/$APP_NAME/Contents/Resources/install-bootstrap.sh"

cat > "$OUTPUT_DIR/build/README.txt" <<'README'
Pummelchen Server Mac Installer

Open "Pummelchen Installer.app".

The installer runs in your user account only. It shows a progress window with
clear install steps, the current release ID, how many mods/resource packs/shader
packs are in the client pack, and where the log file is stored.

Each install step and terminal success/failure status is reported to the
Pummelchen VPS so support can see incomplete installs, direct startup failures,
and successful setup timestamps in SQLite.

On first install it downloads the current verified client pack from the VPS,
which is about 1 GB. Later updates use the installed Pummelchen auto-updater and
sync only changed files from the VPS.

Server: 91.99.176.243:25565
README

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$OUTPUT_DIR/build/$APP_NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$DMG_NAME"
hdiutil create -volname "Pummelchen Client Installer" -srcfolder "$OUTPUT_DIR/build" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
rm -rf "$OUTPUT_DIR/build"
echo "$OUTPUT_DIR/$DMG_NAME"
