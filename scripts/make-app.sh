#!/usr/bin/env bash
# Build Ferry.app — a double-clickable, ad-hoc-signed macOS bundle.
# Usage: scripts/make-app.sh   (output: dist/Ferry.app)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Ferry.app

echo "==> swift build -c release"
swift build -c release --product Ferry

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ferry "$APP/Contents/MacOS/Ferry"
cp icon/Ferry.icns "$APP/Contents/Resources/Ferry.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ferry</string>
  <key>CFBundleDisplayName</key><string>Ferry</string>
  <key>CFBundleIdentifier</key><string>com.qiangxu.ferry</string>
  <key>CFBundleExecutable</key><string>Ferry</string>
  <key>CFBundleIconFile</key><string>Ferry</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> done: $APP"
echo "    Install: drag dist/Ferry.app into /Applications (or ~/Applications)."
