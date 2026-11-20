#!/bin/sh
# Assemble the development DIZUN app (no Xcode project needed), and — unless
# DIZUN_NO_INSTALL=1 — install it as /Applications/DIZUN.app so the user can
# keep it as the default ZIP handler. Default-handler switching itself stays
# a manual user action (project guardrail).
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product DizunApp

APP="build/Dizun.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DizunApp "$APP/Contents/MacOS/DizunApp"
cp scripts/app/Info.plist "$APP/Contents/Info.plist"
if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f Assets/logo.png ]; then
  cp Assets/logo.png "$APP/Contents/Resources/logo.png"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 \
  || codesign --force --sign - "$APP"

# Fail loudly rather than install a stale binary: the executable must be
# newer than every source file that feeds it.
NEWEST_SRC=$(find Sources scripts/app -type f -newer .build/release/DizunApp 2>/dev/null | head -1)
if [ -n "$NEWEST_SRC" ]; then
  echo "stale release build detected ($NEWEST_SRC newer); run: swift build -c release --product DizunApp" >&2
  exit 1
fi

echo "built: $APP"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "${DIZUN_NO_INSTALL:-}" != "1" ]; then
  DEST="/Applications/DIZUN.app"
  # Stop a running copy first so the bundle can be replaced cleanly.
  if pgrep -x DizunApp >/dev/null 2>&1; then
    osascript -e 'tell application id "com.devdoglab.dizun" to quit' >/dev/null 2>&1 || true
    i=0
    while pgrep -x DizunApp >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
      sleep 0.5
      i=$((i + 1))
    done
    if pgrep -x DizunApp >/dev/null 2>&1; then
      echo "DIZUN is still running; install skipped. Close it and rerun." >&2
      exit 1
    fi
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  # Keep Open With clean: register the installed copy, forget the build path.
  "$LSREG" -u "$APP" >/dev/null 2>&1 || true
  "$LSREG" -f "$DEST"
  /System/Library/CoreServices/pbs -update
  echo "installed: $DEST"
else
  "$LSREG" -f "$APP"
  /System/Library/CoreServices/pbs -update
fi

echo "first launch registers the Finder services; to refresh them now:"
echo "  /System/Library/CoreServices/pbs -update"
