#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Yacine TV"
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/backend" "$RESOURCES_DIR/ui"

echo "[1/4] Compiling native arm64 macOS binary (SwiftUI + AVKit + Liquid Glass)..."
/usr/bin/swiftc -O -whole-module-optimization \
  -parse-as-library \
  -framework SwiftUI \
  -framework AVKit \
  -framework AVFoundation \
  -framework WebKit \
  -framework Cocoa \
  -framework Metal \
  -framework MetalFX \
  -framework MetalKit \
  -framework CoreVideo \
  -framework CoreImage \
  -framework QuartzCore \
  "$ROOT_DIR/macos/YacineTVApp.swift" \
  -o "$MACOS_DIR/YacineTV"

echo "[2/4] Bundling resources, Liquid Glass icon assets, and crypto/HLS backend..."
if [[ ! -f "$ROOT_DIR/assets/AppIcon.icns" || "$ROOT_DIR/assets/yacineTV.icon/icon.json" -nt "$ROOT_DIR/assets/AppIcon.icns" ]]; then
  /usr/bin/swift "$ROOT_DIR/scripts/render_icons.swift"
fi
cp "$ROOT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/assets/AppIcon-Default.png" "$RESOURCES_DIR/AppIcon-Default.png"
cp "$ROOT_DIR/assets/AppIcon-Dark.png" "$RESOURCES_DIR/AppIcon-Dark.png"
cp "$ROOT_DIR/assets/AppBrand-Default.png" "$RESOURCES_DIR/AppBrand-Default.png"
cp "$ROOT_DIR/assets/AppBrand-Dark.png" "$RESOURCES_DIR/AppBrand-Dark.png"
cp "$ROOT_DIR/backend/server.py" "$RESOURCES_DIR/backend/server.py"
chmod +x "$RESOURCES_DIR/backend/server.py"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Yacine TV</string>
  <key>CFBundleExecutable</key>
  <string>YacineTV</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>ver3.ycntivi.off.mac</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Yacine TV</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>3.1</string>
  <key>CFBundleVersion</key>
  <string>56</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

echo "[3/4] Code-signing native macOS app bundle..."
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

echo "[4/4] Installing to /Applications/$APP_NAME.app..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
/usr/bin/touch "/Applications/$APP_NAME.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app" || true

echo "Build complete: $APP_BUNDLE"
