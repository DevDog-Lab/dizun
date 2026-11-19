#!/bin/sh
# Assemble the development Dizun.app (no Xcode project needed).
# Output: build/Dizun.app — ad-hoc signed, for local verification only.
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product DizunApp

APP="build/Dizun.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DizunApp "$APP/Contents/MacOS/DizunApp"
cp scripts/app/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP"

echo "built: $APP"
echo "first launch registers the Finder services; to refresh them now:"
echo "  /System/Library/CoreServices/pbs -update"
