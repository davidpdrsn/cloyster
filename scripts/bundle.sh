#!/bin/sh
# Builds build/Cloyster.app. The bundle gives the app its own Accessibility permission, and signing
# with a stable identity is what keeps that permission across rebuilds.
set -eu
cd "$(dirname "$0")/.."

scripts/create-signing-identity.sh
swift build -c release --product cloyster
app=build/Cloyster.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/cloyster "$app/Contents/MacOS/cloyster"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>cloyster</string>
    <key>CFBundleIdentifier</key><string>dev.cloyster.app</string>
    <key>CFBundleName</key><string>Cloyster</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "Cloyster Self-Signed" --timestamp=none "$app"
echo "$app"
