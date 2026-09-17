#!/bin/sh
# Stop NotchLyrics starting at login.
set -e
LABEL="local.notch-lyrics"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "removed the login item"
