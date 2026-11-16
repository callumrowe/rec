#!/usr/bin/env bash
# Builds build/Rec.app: release binary + Info.plist, signed.
#
# macOS keys privacy grants (Microphone, System Audio Recording) to the app's
# designated requirement. An ad-hoc signature's requirement is its code hash, so
# every rebuild looks like a new app and the System Audio Recording grant silently
# stops applying: the tap records pure silence and calls lose the other side.
# Signing with a real certificate makes the requirement "this bundle ID from this
# team", which survives rebuilds. REC_SIGN_IDENTITY overrides the choice; "-"
# forces ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${REC_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  identity=$(grep -o '"Developer ID Application: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)
  [[ -z "$identity" ]] && identity=$(grep -o '"Apple Development: [^"]*"' <<<"$identities" | head -1 | tr -d '"' || true)
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
  identity="-"
  echo "warning: ad-hoc signing; macOS privacy grants will reset on every rebuild (run make reset-permissions after installing)" >&2
fi

swift build -c release
APP=build/Rec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/rec" "$APP/Contents/MacOS/rec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$identity" --identifier com.callumrowe.rec "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed: $identity)"
