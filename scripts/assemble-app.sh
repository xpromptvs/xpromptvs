#!/bin/sh
# Build a separate source edition. No service deployment or official updater.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
MODE=${1:-dev}
case "$MODE" in dev) OPT="";; release) OPT="-c opt";; *) echo 'Expected dev or release' >&2; exit 1;; esac
[ "${RDEV_PRODUCT_PROFILE:-publication}" = publication ] || { echo 'This edition builds the publication profile' >&2; exit 1; }
export RDEV_PRODUCT_PROFILE=publication
IDENTITY=${RDEV_SIGN_IDENTITY:--}
[ -f web/dist/index.html ] && [ -f desktop/dist/renderer/index.html ] || { echo 'Build web and desktop renderers first' >&2; exit 1; }
node scripts/stamp-release.mjs verify web/dist desktop/dist/renderer
node --input-type=module -e 'import {readFileSync} from "node:fs";import {resolveProductFeatures} from "./scripts/lib/product-features.mjs";if(JSON.stringify(JSON.parse(readFileSync("web/dist/product-features.json")))!==JSON.stringify(resolveProductFeatures("publication")))throw Error("Product profile mismatch");'
bazelisk build $OPT --//config:profile=publication "--@rules_apple//apple/build_settings:signing_certificate_name=$IDENTITY" //app:Xpromptvs
APP_ZIP=$(bazelisk cquery $OPT --//config:profile=publication "--@rules_apple//apple/build_settings:signing_certificate_name=$IDENTITY" --output=files //app:Xpromptvs 2>/dev/null | sed -n '/\.zip$/p')
OUT=${RDEV_APP_OUT:-$ROOT/desktop/release-check}
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT";; esac
APP="$OUT/Xpromptvs Development.app"
[ ! -e "$APP" ] || { echo "Output exists; choose a new RDEV_APP_OUT or remove the previous source build: $APP" >&2; exit 1; }
mkdir -p "$OUT"
unzip -q "$APP_ZIP" -d "$OUT"
ditto web/dist "$APP/Contents/Resources/web"
ditto desktop/dist/renderer "$APP/Contents/Resources/ui"
cp web/dist/release.json "$APP/Contents/Resources/release.json"
cp web/src/shared/native-chrome.json "$APP/Contents/Resources/native-chrome.json"
cp desktop/build/icon.icns "$APP/Contents/Resources/icon.icns"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
ditto licenses "$APP/Contents/Resources/licenses"
codesign --force --sign "$IDENTITY" --options=runtime --timestamp=none --preserve-metadata=entitlements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
