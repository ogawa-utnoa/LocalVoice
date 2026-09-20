#!/usr/bin/env bash
# Writes a publishable copy of this repository to <dest> (without build output, models and personal files)
# and fails if anything personal is left in it.
#   ./scripts/export_public.sh ~/Desktop/LocalVoiceInput-public
# Personal words to block (company, names, paths...) go in private/leak-patterns.txt, one regex per line.
# That file is never exported.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:?Usage: $0 <destination directory>}"

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    echo "Destination is not empty: $DEST" >&2
    exit 1
fi
mkdir -p "$DEST"

rsync -a \
    --exclude '.git/' --exclude '.build/' --exclude 'LocalVoiceInput.app/' \
    --exclude 'Models/*.bin' --exclude 'Models/*.gguf' --exclude 'Models/*.part' \
    --exclude 'build.local.env' --exclude 'private/' \
    --exclude '__pycache__/' --exclude '*.pyc' --exclude '.DS_Store' \
    "$ROOT_DIR/" "$DEST/"

# Leak check: absolute home paths always, plus the private pattern list
PATTERNS=('/Users/[A-Za-z0-9._-]+/')
if [ -f "$ROOT_DIR/private/leak-patterns.txt" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && [ "${line#\#}" = "$line" ] && PATTERNS+=("$line")
    done < "$ROOT_DIR/private/leak-patterns.txt"
fi
found=0
for pattern in "${PATTERNS[@]}"; do
    if grep -rInEi -- "$pattern" "$DEST" >/dev/null 2>&1; then
        echo "[leak] pattern matched: $pattern" >&2
        grep -rInEi -- "$pattern" "$DEST" | head -5 >&2
        found=1
    fi
done
if [ "$found" = 1 ]; then
    echo "Export stopped: personal information found in $DEST (fix the source, then export again)." >&2
    exit 1
fi

echo "Exported to $DEST ($(find "$DEST" -type f | wc -l | tr -d ' ') files, leak check passed with ${#PATTERNS[@]} patterns)."
