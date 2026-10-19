#!/bin/bash
# Baut Stamply.app im Ordner build/
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Stamply"
APP="build/${APP_NAME}.app"
VERSION="1.0"

ARCH="$(uname -m)"   # arm64 (Apple Silicon) oder x86_64 (Intel)
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BIN_DIR="build/bin"

# Direkt mit swiftc statt "swift build": braucht den Swift-Paketmanager
# nicht und läuft auch, wenn dieser in den Command Line Tools defekt ist.
echo "→ Kompiliere (Release, $ARCH) …"
mkdir -p "$BIN_DIR"
xcrun swiftc \
    -O \
    -parse-as-library \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macos13.0" \
    -module-name "$APP_NAME" \
    Sources/${APP_NAME}/*.swift \
    -o "$BIN_DIR/$APP_NAME"

echo "→ Erstelle App-Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>local.stamply</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>de</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Optional: eigenes Icon als icon.icns neben dieses Skript legen
if [ -f icon.icns ]; then
    cp icon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "→ Ad-hoc signieren …"
codesign --force --sign - "$APP"

echo
echo "Fertig: $(pwd)/$APP"
echo "Zum Installieren:  cp -R \"$APP\" /Applications/"
