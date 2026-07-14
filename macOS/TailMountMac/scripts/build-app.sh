#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="$ROOT/dist/TailMount.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/TailMountMac" "$CONTENTS/MacOS/TailMountMac"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

ICONSET="$ROOT/.build/TailMount.iconset"
BASE="$ROOT/.build/TailMount-1024.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/IconGenerator.swift" "$BASE"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png"; do
  set -- ${(z)spec}
  sips -z "$1" "$1" "$BASE" --out "$ICONSET/$2" >/dev/null
done
cp "$BASE" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/TailMount.icns"

/usr/bin/codesign --force --deep --sign - "$APP"
echo "构建完成：$APP"
