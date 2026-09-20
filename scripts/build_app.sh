#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_BUNDLE="$ROOT_DIR/LocalVoiceInput.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Optional local overrides (not published): LVI_BUNDLE_ID, LVI_SIGN_IDENTITY
if [ -f "$ROOT_DIR/build.local.env" ]; then
    # shellcheck disable=SC1091
    source "$ROOT_DIR/build.local.env"
fi
BUNDLE_ID="${LVI_BUNDLE_ID:-local.voiceinput.LocalVoiceInput}"

echo "======================================================="
echo "  Building LocalVoiceInput.app (Release)"
echo "======================================================="

cd "$ROOT_DIR"

# 1. Build release binary using Swift Package Manager
swift build -c release --product LocalVoiceInputApp

# 2. Prepare .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$BUILD_DIR/LocalVoiceInputApp" "$MACOS_DIR/LocalVoiceInput"

# 3. Create Info.plist with LSUIElement=1 (menu bar only) and microphone permissions
cat << EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LocalVoiceInput</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>LocalVoiceInput</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>マイク音声をローカルで文字起こしするためにマイクへのアクセス権限が必要です。音声は外部へ送信されません。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>アクティブな入力欄へ文字起こし文章を直接挿入するために権限が必要です。</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>フォーカス中の入力欄に文字を自動挿入するためにアクセシビリティ権限が必要です。</string>
</dict>
</plist>
EOF

# 4. Code sign the whole bundle with a fixed identifier (binds Info.plist).
#    Ad-hoc ("-") signatures change on every rebuild, and macOS then treats the rebuilt app as a different app:
#    the Accessibility toggle still looks ON but no longer applies. Set LVI_SIGN_IDENTITY (in build.local.env)
#    to a code signing certificate name (e.g. a self-signed one created in Keychain Access) to keep permissions.
SIGN_IDENTITY="${LVI_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE"
codesign --verify "$APP_BUNDLE"

echo "✓ Created $APP_BUNDLE (signed with: $SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo ""
    echo "NOTE: ad-hoc signed. After a rebuild, re-grant Accessibility:"
    echo "  tccutil reset Accessibility $BUNDLE_ID   # then relaunch and allow"
fi
echo "Done! You can launch the app by running:"
echo "open $APP_BUNDLE"
