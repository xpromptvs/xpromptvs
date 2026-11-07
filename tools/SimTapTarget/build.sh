#!/usr/bin/env sh
# Build the SimTapTarget iOS-simulator app (no Xcode project) into build/SimTapTarget.app, for scripts/gate-simulator.sh.
# Prints ONLY the .app path on stdout (diagnostics go to stderr).
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$DIR/build"
APP="$OUT/SimTapTarget.app"
rm -rf "$OUT"
mkdir -p "$APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun -sdk iphonesimulator swiftc \
  -target "$(uname -m)-apple-ios26.0-simulator" \
  -sdk "$SDK" \
  -parse-as-library \
  -o "$APP/SimTapTarget" \
  "$DIR/Main.swift" 1>&2
cp "$DIR/Info.plist" "$APP/Info.plist"
# AD-HOC SIGNED: a recent simulator runtime refuses to install an unsigned app.
codesign --force --sign - "$APP" 1>&2
echo "$APP"
