#!/bin/sh
# Build NotchLyrics.app.
#
# A real .app bundle (not a bare binary) matters: macOS attributes Automation
# permission for controlling Spotify to the bundle identity, so the prompt is
# asked once and remembered, instead of inheriting whatever terminal launched it.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/NotchLyrics.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

xcrun swiftc -O -o "$MACOS/NotchLyrics" "$ROOT/Sources/main.swift" \
	-framework AppKit -framework Foundation

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>NotchLyrics</string>
	<key>CFBundleIdentifier</key><string>local.notch-lyrics</string>
	<key>CFBundleExecutable</key><string>NotchLyrics</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Reads the current track and playback position from Spotify to sync lyrics.</string>
</dict>
PLIST
echo '</plist>' >> "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"
