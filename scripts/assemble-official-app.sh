#!/usr/bin/env sh
# Official, terminal-first distribution. Source builds use assemble-app.sh.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
log() { printf '[Xpromptvs] %s\n' "$*"; }
warn() { printf '[Xpromptvs] %s\n' "$*" >&2; }
die() { warn "$*"; exit 1; }
[ "${RDEV_PRODUCT_PROFILE:-publication}" = publication ] || { echo 'Official edition requires publication product profile' >&2; exit 1; }
export RDEV_PRODUCT_PROFILE=publication
[ "${1:-}" = release ] || { echo "Official distribution requires release mode" >&2; exit 1; }
[ "${RDEV_NOTARIZE:-1}" = 1 ] || { echo "Official distribution requires notarization" >&2; exit 1; }
: "${RDEV_SIGN_IDENTITY:?Official distribution requires RDEV_SIGN_IDENTITY}"
[ -n "${RDEV_RELEASE_RECORD:-}" ] || { echo 'Official distribution requires a release record' >&2; exit 1; }
MODE=${1:-dev}
case "$MODE" in dev) OPT="" ;; release) OPT="-c opt" ;; *) die "usage: assemble-app.sh [dev|release]" ;; esac

[ -f "$ROOT/web/dist/index.html" ] || die "web/dist is missing — npm --prefix web run build"
[ -f "$ROOT/desktop/dist/renderer/index.html" ] || die "desktop/dist/renderer is missing — npm --prefix desktop run build"

node "$ROOT/scripts/stamp-release.mjs" verify "$ROOT/web/dist" "$ROOT/desktop/dist/renderer"
node --input-type=module -e 'import {readFileSync} from "node:fs";const f=JSON.parse(readFileSync("web/dist/product-features.json"));if(f.graphicalAgents!==false||f.glasses!==false)throw Error("Official release must use publication features");const r=JSON.parse(readFileSync(process.env.RDEV_RELEASE_RECORD));if(r.channel!=="public"||r.published!==true)throw Error("Expected published public release record");'

# shellcheck disable=SC2086
(cd "$ROOT" && bazelisk build $OPT --//config:profile=publication --//config:distribution=official "--@rules_apple//apple/build_settings:signing_certificate_name=$RDEV_SIGN_IDENTITY" //app:Xpromptvs //app/update-helper:XpromptvsUpdate)

# Apple app and command-line helper use different Bazel configurations. Resolve each output,
# rather than relying on bazel-bin (which can point at only one configuration).
APP_ZIP=$(cd "$ROOT" && bazelisk cquery $OPT --//config:profile=publication --//config:distribution=official "--@rules_apple//apple/build_settings:signing_certificate_name=$RDEV_SIGN_IDENTITY" --output=files //app:Xpromptvs 2>/dev/null | sed -n '/\.zip$/p')
UPDATE_HELPER=$(cd "$ROOT" && bazelisk cquery $OPT --//config:profile=publication --//config:distribution=official "--@rules_apple//apple/build_settings:signing_certificate_name=$RDEV_SIGN_IDENTITY" --output=files //app/update-helper:XpromptvsUpdate 2>/dev/null | head -1)
[ -f "$ROOT/$APP_ZIP" ] || die "Bazel app archive is missing"
[ -f "$ROOT/$UPDATE_HELPER" ] || die "Bazel update helper is missing"
: "${RDEV_APP_OUT:?Official builds require a fresh RDEV_APP_OUT}"
OUT=$RDEV_APP_OUT
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
APP="$OUT/Xpromptvs.app"
[ ! -e "$APP" ] || die "Output already exists: $APP"; mkdir -p "$OUT"
unzip -q -o "$ROOT/$APP_ZIP" -d "$OUT"
ditto "$ROOT/web/dist" "$APP/Contents/Resources/web"
ditto "$ROOT/desktop/dist/renderer" "$APP/Contents/Resources/ui"
[ ! -e "$ROOT/desktop/dist/agents" ] || die "Publication must not bundle graphical agent helpers"
cp "$ROOT/web/dist/release.json" "$APP/Contents/Resources/release.json"
python3 - "$APP" "$ROOT/desktop/build/icon.icns" <<'PYTHON'
import hashlib, json, plistlib, shutil, sys
from pathlib import Path
app=Path(sys.argv[1]); r=json.loads((app/'Contents/Resources/release.json').read_text())
p=app/'Contents/Info.plist'
v=plistlib.loads(p.read_bytes()); v['CFBundleVersion']=str(r['build']); v['CFBundleShortVersionString']=r['version']
if r['channel']=='staging': v['CFBundleDisplayName']='Xpromptvs Staging'; v['CFBundleName']='Xpromptvs Staging'
# Dev bundles can retain the same version. Give changed artwork a distinct resource identity
# for Launch Services; keep icon.icns for tools inspecting it.
icon=Path(sys.argv[2]); icon_name='icon-'+hashlib.sha256(icon.read_bytes()).hexdigest()[:16]
shutil.copyfile(icon,app/'Contents/Resources/icon.icns')
shutil.copyfile(icon,app/('Contents/Resources/'+icon_name+'.icns'))
v['CFBundleIconFile']=icon_name
p.write_bytes(plistlib.dumps(v))
PYTHON
cp "$ROOT/web/src/shared/native-chrome.json" "$APP/Contents/Resources/native-chrome.json"
# The resources changed the bundle's seal, so it is signed again: with the identity rules_apple used
# (read back, so .bazelrc stays its one source — TCC's requirement is that team and identifier), and
# KEEPING its entitlements and hardened runtime, which a bare `--force` re-sign drops. Notarization
# needs a SECURE timestamp; a dev build asks Apple's timestamp server nothing.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
case "$IDENTITY" in "Developer ID Application: "*) ;; *) die "rules_apple did not sign with a Developer ID identity (got '$IDENTITY') — .bazelrc" ;; esac
mkdir -p "$APP/Contents/Helpers"
cp "$ROOT/$UPDATE_HELPER" "$APP/Contents/Helpers/XpromptvsUpdate"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
ditto licenses "$APP/Contents/Resources/licenses"
TIMESTAMP=--timestamp=none; [ "$MODE" = release ] && TIMESTAMP=--timestamp
codesign --force --sign "$IDENTITY" --options=runtime "$TIMESTAMP" "$APP/Contents/Helpers/XpromptvsUpdate"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags,runtime "$TIMESTAMP" "$APP"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -q '^CodeDirectory .*flags=.*(runtime)' || die "the re-sign lost the hardened runtime"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q 'webcredentials:xpromptvs.ai' || die "the re-sign lost the entitlements"

# notarize FILE — submit it, wait for Apple's verdict, and refuse (printing Apple's log) unless it is Accepted.
notarize() {
  _res="$OUT/.notary.json"
  log "notarizing $(basename "$1") (keychain profile $NOTARY)…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY" --wait --output-format json >"$_res" || true
  _status=$(plutil -extract status raw -o - "$_res" 2>/dev/null || echo none)
  if [ "$_status" != Accepted ]; then
    _id=$(plutil -extract id raw -o - "$_res" 2>/dev/null || true)
    cat "$_res" >&2; [ -n "$_id" ] && xcrun notarytool log "$_id" --keychain-profile "$NOTARY" >&2
    rm -f "$_res"; die "notarization of $(basename "$1") was not accepted ($_status)"
  fi
  rm -f "$_res"
}

if [ "$MODE" = release ]; then
  rm -f "$OUT/Xpromptvs.zip" "$OUT/Xpromptvs.dmg"
  NOTARY=${RDEV_NOTARY_PROFILE:-rdev-notary}
  if [ "${RDEV_NOTARIZE:-1}" = 0 ]; then
    warn "RDEV_NOTARIZE=0: NOT notarized — Gatekeeper refuses this download on another Mac"
  else
    xcrun notarytool history --keychain-profile "$NOTARY" >/dev/null 2>&1 \
      || die "no notarytool credential '$NOTARY' in the keychain (docs/desktop-app.md, \"Signing and notarization\"), or Apple is unreachable — RDEV_NOTARIZE=0 builds without"
    # The app first, so the .zip and the .dmg both carry a STAPLED app (a first launch offline checks it).
    ditto -c -k --keepParent "$APP" "$OUT/Xpromptvs.zip"
    notarize "$OUT/Xpromptvs.zip"
    xcrun stapler staple -q "$APP"
    rm -f "$OUT/Xpromptvs.zip"
  fi
  ditto -c -k --keepParent "$APP" "$OUT/Xpromptvs.zip"
  hdiutil create -quiet -volname Xpromptvs -srcfolder "$APP" -ov -format UDZO "$OUT/Xpromptvs.dmg"
  codesign --sign "$IDENTITY" "$TIMESTAMP" "$OUT/Xpromptvs.dmg"
  if [ "${RDEV_NOTARIZE:-1}" != 0 ]; then
    notarize "$OUT/Xpromptvs.dmg"
    xcrun stapler staple -q "$OUT/Xpromptvs.dmg"
    spctl --assess --type execute -vv "$APP" 2>&1 | grep -q 'source=Notarized Developer ID' \
      || die "Gatekeeper does not accept the stapled app: $(spctl --assess --type execute -vv "$APP" 2>&1)"
  fi
fi
log "assembled $APP ($MODE)"
