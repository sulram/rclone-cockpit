#!/usr/bin/env bash
# Package the menu-bar binary into a minimal macOS .app bundle.
#
# menuet v2 initializes UNUserNotificationCenter on startup, which requires the
# process to run from inside a bundle (a bare binary aborts with
# "bundleProxyForCurrentProcess is nil"). LSUIElement=true keeps it menu-bar-only
# (no Dock icon). The bundle is unsigned — fine for local use; distribution would
# need codesign + notarization (and notifications need signing to be delivered).
set -euo pipefail

APP_NAME="RcloneCockpit"
BUNDLE_ID="com.marlus.rclone-cockpit"
VERSION="0.1.0"

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/$APP_NAME.app"
macos="$app/Contents/MacOS"

echo "› building menubar binary..."
mkdir -p "$macos"
CGO_ENABLED=1 go build -o "$macos/$APP_NAME" "$root/cmd/menubar"

echo "› writing Info.plist..."
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>rclone cockpit</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "✓ built $app"
echo "  run:  open '$app'                 (launches into the menu bar)"
echo "  or:   '$macos/$APP_NAME'          (foreground, logs to terminal)"
