#!/usr/bin/env sh
# Build the WinTapTarget macOS app (no Xcode project) into build/WinTapTarget.app.
# Prints ONLY the .app path on stdout (diagnostics go to stderr).
#
# NOTE no -parse-as-library, unlike tools/SimTapTarget: main.swift uses top-level code, and the two
# are mutually exclusive.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$DIR/build"
APP="$OUT/WinTapTarget.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun -sdk macosx swiftc \
  -target "$(uname -m)-apple-macos26.0" \
  -sdk "$SDK" \
  -o "$APP/Contents/MacOS/WinTapTarget" \
  "$DIR/main.swift" 1>&2
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
echo "$APP"
