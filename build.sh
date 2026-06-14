#!/bin/bash
# Build UsageWidget.swift into "Usage Widget.app" and install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="Usage Widget.app"

swiftc -O UsageWidget.swift -o UsageWidget

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp UsageWidget "$APP/Contents/MacOS/UsageWidget"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>UsageWidget</string>
    <key>CFBundleIdentifier</key><string>local.harrison.usage-widget</string>
    <key>CFBundleName</key><string>Usage Widget</string>
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
