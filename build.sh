#!/bin/bash
# Builds Caffeinate.app from source and ad-hoc signs it.
# Usage: ./build.sh [--install]
set -e

cd "$(dirname "$0")"

echo "Building release binary..."
ARCHS="--arch arm64 --arch x86_64"  # universal: Apple Silicon + Intel
swift build -c release $ARCHS
OUT=$(swift build -c release $ARCHS --show-bin-path)

BUNDLE="Caffeinate.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$OUT/CaffeinateApp" "$BUNDLE/Contents/MacOS/Caffeinate"
chmod +x "$BUNDLE/Contents/MacOS/Caffeinate"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/failsafe.sh Resources/caffeinate-my-mac "$BUNDLE/Contents/Resources/"
chmod +x "$BUNDLE/Contents/Resources/failsafe.sh" "$BUNDLE/Contents/Resources/caffeinate-my-mac"

APPEX="$BUNDLE/Contents/PlugIns/CaffeinateWidget.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$OUT/CaffeinateWidget" "$APPEX/Contents/MacOS/CaffeinateWidget"
cp WidgetInfo.plist "$APPEX/Contents/Info.plist"

echo "Code signing (ad-hoc)..."
# Sign the widget first with its sandbox entitlements; --deep would strip them.
codesign --force -s - --entitlements Widget.entitlements "$APPEX"
codesign --force -s - "$BUNDLE"

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
