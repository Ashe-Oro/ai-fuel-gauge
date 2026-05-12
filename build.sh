#!/usr/bin/env bash
# Build Claude Usage.app using Command Line Tools only (no Xcode required).
#
# Usage: ./build.sh [release|debug]
set -euo pipefail

CONFIG="${1:-debug}"
APP_NAME="Claude Usage"
BUNDLE_ID="com.claudeusage.app"
VERSION="0.1.0"
TARGET="arm64-apple-macos14.0"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

case "$CONFIG" in
  release) OPTIMIZE=(-O) ;;
  debug)   OPTIMIZE=(-Onone -g) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

echo "→ Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "→ Compiling Swift sources ($CONFIG)"
swiftc \
  -target "$TARGET" \
  -parse-as-library \
  "${OPTIMIZE[@]}" \
  ClaudeUsageWidget/Sources/App/ClaudeUsageWidgetApp.swift \
  ClaudeUsageWidget/Sources/Models/UsageModels.swift \
  ClaudeUsageWidget/Sources/Services/QuotaFetcher.swift \
  ClaudeUsageWidget/Sources/Services/CodexFetcher.swift \
  ClaudeUsageWidget/Sources/Services/UsageStore.swift \
  ClaudeUsageWidget/Sources/Views/Components.swift \
  ClaudeUsageWidget/Sources/Views/MenuBarDropdown.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "→ Bundling resources"
cp ClaudeUsageWidget/Resources/fetch-quota.exp "$APP_DIR/Contents/Resources/"
chmod +x "$APP_DIR/Contents/Resources/fetch-quota.exp"

echo "→ Writing Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>            <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>             <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>             <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                   <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>$VERSION</string>
    <key>CFBundleVersion</key>                <string>1</string>
    <key>LSMinimumSystemVersion</key>         <string>14.0</string>
    <key>LSUIElement</key>                    <true/>
    <key>NSHighResolutionCapable</key>        <true/>
</dict>
</plist>
EOF

echo "→ Ad-hoc codesigning"
codesign --force --sign - "$APP_DIR" 2>&1 | sed 's/^/   /'

echo
echo "✓ Built $APP_DIR"
echo "  Run:    open '$APP_DIR'"
echo "  Or:     '$APP_DIR/Contents/MacOS/$APP_NAME'"
