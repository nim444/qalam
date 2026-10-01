#!/usr/bin/env bash
# Builds the Mac menu-bar app into mac/build/Qalam.app (ad-hoc signed, not notarized).
# Install: cp -R mac/build/Qalam.app /Applications/ && open /Applications/Qalam.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
APP="$ROOT/mac/build/Qalam.app"

cd "$ROOT/mac"
swift build -c release --product Qalam 2>&1 | grep -E "error|Compiling|Build complete" || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Qalam "$APP/Contents/MacOS/Qalam"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/assets/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ROOT/assets/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ro.soluzy.qalam</string>
  <key>CFBundleName</key><string>Qalam</string>
  <key>CFBundleDisplayName</key><string>Qalam</string>
  <key>CFBundleExecutable</key><string>Qalam</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Qalam listens for your phone's pen on the local network.</string>
  <key>NSBonjourServices</key><array><string>_qalam._udp</string></array>
  <key>NSHumanReadableCopyright</key><string>Apache-2.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier ro.soluzy.qalam "$APP"
echo "Built $APP"
