#!/bin/sh
# Start NotchLyrics at login and keep it running.
#
# A LaunchAgent rather than a Login Item: it restarts the app if it ever exits,
# and it is a plain file you can read, edit or delete.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/NotchLyrics.app/Contents/MacOS/NotchLyrics"
LABEL="local.notch-lyrics"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -x "$BIN" ] || { echo "build it first: ./build.sh"; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardErrorPath</key><string>/tmp/notch-lyrics.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST"
