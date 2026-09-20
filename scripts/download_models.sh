#!/usr/bin/env bash
# Downloads the models listed in Models/manifest.tsv and verifies their SHA-256.
#   ./scripts/download_models.sh            # recommended set (~1.7GB): Whisper large-v3-turbo + Qwen2.5 1.5B
#   ./scripts/download_models.sh full       # + low-memory fallbacks (~2.7GB): Whisper small + Qwen2.5 0.5B
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$ROOT_DIR/Models"
MANIFEST="$MODELS_DIR/manifest.tsv"
TARGET="${1:-recommended}"

case "$TARGET" in
    recommended) SETS="recommended" ;;
    full)        SETS="recommended lowmemory" ;;
    *) echo "Usage: $0 [recommended|full]"; exit 1 ;;
esac

mkdir -p "$MODELS_DIR"
echo "=== LocalVoiceInput model download ($TARGET) -> $MODELS_DIR"

verify() { # file sha256
    [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]
}

while IFS=$'\t' read -r set file sha bytes url; do
    case "$set" in ''|'#'*) continue ;; esac
    case " $SETS " in *" $set "*) ;; *) continue ;; esac
    dest="$MODELS_DIR/$file"
    if [ -f "$dest" ] && verify "$dest" "$sha"; then
        echo "[ok] $file (already present, checksum verified)"
        continue
    fi
    echo "[download] $file ($((bytes / 1000000)) MB)"
    curl -L --fail --retry 3 -C - --progress-bar -o "$dest.part" "$url"
    if ! verify "$dest.part" "$sha"; then
        echo "[error] checksum mismatch for $file — the download is broken or the file changed upstream." >&2
        rm -f "$dest.part"
        exit 1
    fi
    mv "$dest.part" "$dest"
    echo "[ok] $file"
done < "$MANIFEST"

echo "=== Models ready."
