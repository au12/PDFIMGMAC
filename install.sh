#!/bin/bash
# Installs Pluck into ~/Library/PDF Services so it shows up in every Print dialog
# (PDF ▾ ▸ "Extract Images to Downloads").
#
# Works from a git checkout (builds from source) or from a release zip that
# already contains Pluck.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

MENU_NAME="Extract Images to Downloads"
DEST_DIR="$HOME/Library/PDF Services"
DEST="$DEST_DIR/$MENU_NAME.app"

if [[ -d "Pluck.app" && ! -f "Sources/main.swift" ]]; then
  SRC="Pluck.app"                       # prebuilt (release zip)
else
  ./build.sh
  SRC="build/Pluck.app"
fi

mkdir -p "$DEST_DIR"
# Quit a running copy (e.g. settings window) before replacing it.
pkill -x Pluck 2>/dev/null || true
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

# Handy command-line entry point: pluck --extract file.pdf
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Contents/MacOS/Pluck" "$HOME/.local/bin/pluck"

cat <<EOF

✓ Installed: $DEST

Use it:  File ▸ Print… (⌘P) ▸ PDF ▾ (bottom-left) ▸ "$MENU_NAME"
Images land in ~/Downloads/<document name> images/

The first time, macOS asks to let Pluck access your Downloads folder — click Allow.
Settings (folder vs. zip, keep original JPEGs):  open "$DEST"
EOF
