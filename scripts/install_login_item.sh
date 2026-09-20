#!/usr/bin/env bash
# Starts LocalVoiceInput automatically when you log in (macOS LaunchAgent).
#   ./scripts/install_login_item.sh              # install and start now
#   ./scripts/install_login_item.sh --uninstall  # stop starting it automatically
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT_DIR/build.local.env" ] && source "$ROOT_DIR/build.local.env"
LABEL="${LVI_BUNDLE_ID:-local.voiceinput.LocalVoiceInput}"
APP="$ROOT_DIR/LocalVoiceInput.app"
BIN="$APP/Contents/MacOS/LocalVoiceInput"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed: $PLIST (the app no longer starts at login)"
    exit 0
fi

[ -x "$BIN" ] || { echo "Build the app first: ./scripts/build_app.sh" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed: $PLIST"
echo "LocalVoiceInput now starts when you log in (quitting it from the menu does not restart it until the next login)."
