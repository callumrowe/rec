#!/usr/bin/env bash
# Builds build/Rec.app: release binary + Info.plist, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Rec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/rec" "$APP/Contents/MacOS/rec"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.callumrowe.rec "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
