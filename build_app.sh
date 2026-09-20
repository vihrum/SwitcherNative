#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

APP_NAME="SwitcherNative.app"
APP_DIR="$DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Packaging into $APP_NAME..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$DIR/.cache"

echo "==> Compiling SwitcherNative (release, native arm64)..."
swiftc -O \
    -module-cache-path "$DIR/.cache" \
    -framework Cocoa \
    -framework Carbon \
    "$DIR"/Sources/SwitcherNative/*.swift \
    -o "$MACOS_DIR/SwitcherNative"

chmod +x "$MACOS_DIR/SwitcherNative"

echo "==> Copying resources..."
if [ -d "$DIR/Resources" ]; then
    cp -R "$DIR/Resources/"* "$RESOURCES_DIR/" 2>/dev/null || true
fi

echo "==> Writing Info.plist..."
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SwitcherNative</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>ua.switcher.native</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SwitcherNative</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>SwitcherNative потребує доступу до клавіатури для автоматичного перемикання розкладки та виправлення введеного тексту.</string>
</dict>
</plist>
EOF

echo "==> Signing $APP_NAME with stable designated requirement..."
codesign --force --deep --sign - --requirements '=designated => identifier "ua.switcher.native"' "$APP_DIR"

echo "==> Verifying signature..."
codesign -vvv --display --requirements - "$APP_DIR"

echo "==> Done! Successfully built $APP_DIR"
