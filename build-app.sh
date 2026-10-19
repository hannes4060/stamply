#!/bin/bash
# Baut Stamply.app im Ordner build/
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Stamply"
APP="build/${APP_NAME}.app"
VERSION="1.0"

ARCH="$(uname -m)"   # arm64 (Apple Silicon) oder x86_64 (Intel)
BIN_DIR="build/bin"
LOG="build/compile.log"
mkdir -p "$BIN_DIR"

compile() {
    xcrun swiftc \
        -O \
        -parse-as-library \
        -sdk "$1" \
        -target "${ARCH}-apple-macos13.0" \
        -module-name "$APP_NAME" \
        Sources/${APP_NAME}/*.swift \
        -o "$BIN_DIR/$APP_NAME"
}

# Kandidaten: ein per SDK=... vorgegebenes SDK, sonst das Standard-SDK und
# danach alle weiteren installierten macOS-SDKs, neueste zuerst. Ältere SDKs
# werden nur probiert, wenn das SDK nicht zum Compiler passt (halb
# aktualisierte Command Line Tools).
if [ -n "${SDK:-}" ]; then
    CANDIDATES=("$SDK")
else
    DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path)"
    CANDIDATES=("$DEFAULT_SDK")
    SDK_DIR="$(dirname "$DEFAULT_SDK")"
    while IFS= read -r s; do
        [ "$(cd "$s" && pwd -P)" = "$(cd "$DEFAULT_SDK" && pwd -P)" ] || CANDIDATES+=("$s")
    done < <(ls -d "$SDK_DIR"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV)
fi

# Direkt mit swiftc statt "swift build": braucht den Swift-Paketmanager nicht.
BUILT=0
for CANDIDATE in "${CANDIDATES[@]}"; do
    echo "→ Kompiliere (Release, $ARCH, SDK: $(basename "$CANDIDATE")) …"
    if compile "$CANDIDATE" 2> "$LOG"; then
        BUILT=1
        break
    fi
    if grep -q "this SDK is not supported by the compiler" "$LOG"; then
        echo "  SDK passt nicht zum Compiler, versuche nächstes …"
        continue
    fi
    cat "$LOG" >&2
    exit 1
done

if [ "$BUILT" -ne 1 ]; then
    cat "$LOG" >&2
    echo >&2
    echo "Kein installiertes SDK passt zum Swift-Compiler." >&2
    echo "Command Line Tools neu installieren:" >&2
    echo "  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install" >&2
    exit 1
fi

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
