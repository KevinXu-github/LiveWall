#!/bin/bash
# Installs the latest LiveWall and opens it:
#   curl -fsSL https://raw.githubusercontent.com/KevinXu-github/LiveWall/main/install.sh | bash
set -euo pipefail

URL="https://github.com/KevinXu-github/LiveWall/releases/latest/download/LiveWall.zip"
APPS="/Applications"
[ -w "$APPS" ] || { APPS="$HOME/Applications"; mkdir -p "$APPS"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading LiveWall…"
curl -fsSL "$URL" -o "$TMP/LiveWall.zip"
ditto -x -k "$TMP/LiveWall.zip" "$TMP"

pkill -x LiveWall 2>/dev/null || true
rm -rf "$APPS/LiveWall.app"
ditto "$TMP/LiveWall.app" "$APPS/LiveWall.app"
open "$APPS/LiveWall.app"

echo "Done. Pick a video, and you're set. LiveWall lives in your menu bar as a ▶︎ icon."
