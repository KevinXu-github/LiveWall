#!/bin/bash
# Builds LiveWall.app.
#   bash build.sh            build for this Mac, install to /Applications, launch
#   bash build.sh --release  build for Apple Silicon + Intel, zip to dist/ (no install, no bundled video)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.1.0}"
RELEASE=false
[ "${1:-}" = "--release" ] && RELEASE=true

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's command-line developer tools are missing. Installing — rerun this script when that finishes."
  xcode-select --install
  exit 1
fi

APP="LiveWall.app"
BIN="$APP/Contents/MacOS/LiveWall"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
if $RELEASE; then
  for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13" -o "$BIN-$arch" LiveWall.swift
  done
  lipo -create -output "$BIN" "$BIN-arm64" "$BIN-x86_64"
  rm "$BIN-arm64" "$BIN-x86_64"
else
  swiftc -O -target "$(uname -m)-apple-macos13" -o "$BIN" LiveWall.swift
  # Optional: a wallpaper.mp4/.mov/.m4v next to this script becomes the default video.
  for f in wallpaper.mp4 wallpaper.mov wallpaper.m4v; do
    [ -f "$f" ] && { cp "$f" "$APP/Contents/Resources/"; break; }
  done
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LiveWall</string>
  <key>CFBundleIdentifier</key><string>io.github.kevinxu-github.livewall</string>
  <key>CFBundleExecutable</key><string>LiveWall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Video</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.movie</string></array>
  </dict></array>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

if $RELEASE; then
  mkdir -p dist
  rm -f dist/LiveWall.zip
  ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" dist/LiveWall.zip
  echo "Built dist/LiveWall.zip (version $VERSION, Apple Silicon + Intel)."
  exit 0
fi

pkill -x LiveWall 2>/dev/null || true
rm -rf /Applications/LiveWall.app
cp -R "$APP" /Applications/
open /Applications/LiveWall.app
echo "LiveWall is running. Look for the ▶︎ icon in your menu bar."
