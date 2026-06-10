#!/bin/bash
# Build ClaudeUsageWidget.swift into "Claude Usage.app" and install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="Claude Usage.app"

swiftc -O ClaudeUsageWidget.swift -o ClaudeUsage

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ClaudeUsage "$APP/Contents/MacOS/ClaudeUsage"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeUsage</string>
    <key>CFBundleIdentifier</key><string>local.harrison.claude-usage</string>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/"$APP"
cp -R "$APP" ~/Applications/

echo "Installed: ~/Applications/$APP"
