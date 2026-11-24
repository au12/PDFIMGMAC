#!/bin/bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/au12/PDFIMGMAC/main/get.sh | bash
set -euo pipefail
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "→ Downloading latest Pluck build…"
curl -fsSL -o "$TMP/Pluck.zip" "https://github.com/au12/PDFIMGMAC/releases/download/latest/Pluck.zip"
ditto -x -k "$TMP/Pluck.zip" "$TMP"
bash "$TMP/Pluck/install.sh"
