#!/usr/bin/env bash
# LocalVoice one-shot setup:
#   check Mac -> install whisper.cpp / llama.cpp (only if missing) -> download models (SHA-256 verified)
#   -> build LocalVoice.app -> run tests -> launch
#
#   ./setup.sh                 # recommended models (~1.7GB), tests, launch
#   ./setup.sh --full          # also low-memory fallback models (~2.7GB total)
#   ./setup.sh --skip-tests    # skip the test suite
#   ./setup.sh --no-launch     # do not open the app at the end
#
# Nothing is sent anywhere after setup: speech and text stay on this Mac.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_SET="recommended"
RUN_TESTS=1
LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --full) MODEL_SET="full" ;;
        --skip-tests) RUN_TESTS=0 ;;
        --no-launch) LAUNCH=0 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
fail() { echo ""; echo "[setup failed] $*" >&2; exit 1; }

cd "$ROOT_DIR"

step "1/6 Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || fail "macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Apple Silicon (M1 or later) is required."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || fail "macOS 14 (Sonoma) or later is required. This Mac: $(sw_vers -productVersion)"
xcode-select -p >/dev/null 2>&1 || fail "Xcode Command Line Tools are missing. Run: xcode-select --install  (then run ./setup.sh again)"
command -v swift >/dev/null 2>&1 || fail "swift not found. Run: xcode-select --install"
echo "ok: macOS $(sw_vers -productVersion), $(uname -m), $(swift --version 2>/dev/null | head -1)"

step "2/6 Speech / text engines (whisper.cpp, llama.cpp)"
BREW="$(command -v brew || true)"
[ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
need_tool() { # binary formula
    if [ -x "/opt/homebrew/bin/$1" ] || [ -x "/usr/local/bin/$1" ]; then
        echo "ok: $1 already installed (left untouched)"
        return
    fi
    [ -n "$BREW" ] || fail "Homebrew is required to install $2. Install it from https://brew.sh and run ./setup.sh again."
    echo "installing $2 ..."
    "$BREW" install "$2"
    { [ -x "/opt/homebrew/bin/$1" ] || [ -x "/usr/local/bin/$1" ]; } || fail "$1 is still missing after 'brew install $2'."
}
need_tool whisper-cli whisper-cpp
need_tool llama-completion llama.cpp

step "3/6 Models ($MODEL_SET)"
./scripts/download_models.sh "$MODEL_SET"

step "4/6 Building LocalVoice.app"
./scripts/build_app.sh

if [ "$RUN_TESTS" = 1 ]; then
    step "5/6 Tests (includes a real speech end-to-end check when a Japanese voice is available)"
    swift run -c debug LocalVoiceTests
else
    step "5/6 Tests skipped"
fi

step "6/6 Done"
if [ "$LAUNCH" = 1 ]; then
    open "$ROOT_DIR/LocalVoice.app"
    echo "LocalVoice is running (🎙️ in the menu bar)."
fi
cat <<'MSG'

Two permissions must be granted by you (macOS does not allow apps to grant them):
  1. Microphone    — answer "Allow" when asked on the first recording.
  2. Accessibility — System Settings > Privacy & Security > Accessibility > turn LocalVoice ON
                     (the 🎙️ menu shows "⚠️ アクセシビリティ権限が無効…" until this is done).

Use: put the cursor in any text field, press Option+Space, speak, press Option+Space again.
MSG
