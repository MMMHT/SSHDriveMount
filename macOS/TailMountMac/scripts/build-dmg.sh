#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build-app.sh"
STAGE="$ROOT/.build/dmg"
OUTPUT="$ROOT/dist/TailMount-macOS-0.1.0.dmg"
rm -rf "$STAGE" "$OUTPUT"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/TailMount.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TailMount" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT"
echo "DMG 已生成：$OUTPUT"
