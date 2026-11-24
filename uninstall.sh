#!/bin/bash
# Removes Pluck from the Print dialog and deletes its settings.
set -euo pipefail
pkill -x Pluck 2>/dev/null || true
rm -rf "$HOME/Library/PDF Services/Extract Images to Downloads.app"
rm -f "$HOME/.local/bin/pluck"
defaults delete com.au12.pluck 2>/dev/null || true
echo "✓ Pluck removed."
