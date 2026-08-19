#!/bin/bash
# Builds Caffeinate.app from source and ad-hoc signs it.
# Usage: ./build.sh [--install]
set -e

cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release

BUNDLE="Caffeinate.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/CaffeinateApp "$BUNDLE/Contents/MacOS/Caffeinate"
chmod +x "$BUNDLE/Contents/MacOS/Caffeinate"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Code signing (ad-hoc)..."
codesign --force --deep -s - "$BUNDLE"

echo "Built $BUNDLE"

if [ "$1" == "--install" ]; then
  DEST="/Applications/Caffeinate.app"
  if [ -w /Applications ]; then
    rm -rf "$DEST"
    cp -R "$BUNDLE" "$DEST"
    echo "Installed to $DEST"
  else
    mkdir -p ~/Applications
    rm -rf ~/Applications/Caffeinate.app
    cp -R "$BUNDLE" ~/Applications/Caffeinate.app
    echo "Installed to ~/Applications/Caffeinate.app"
  fi
fi
