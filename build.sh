#!/bin/bash
# Builds build/Pluck.app (Apple Silicon). Needs Xcode or the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-arm64}"
APP="build/Pluck.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools with:  xcode-select --install" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling ($ARCH)…"
xcrun swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -framework AppKit -framework SwiftUI \
  -o "$APP/Contents/MacOS/Pluck" Sources/main.swift

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Building icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing (ad-hoc)…"
codesign --force --sign - --identifier com.au12.pluck "$APP"

echo "✓ Built $APP"
